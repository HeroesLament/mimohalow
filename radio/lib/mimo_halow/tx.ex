defmodule MimoHalow.Tx do
  @moduledoc """
  One-PPDU-per-key transmit over the board's cyclic TX DMA ring
  (`Nervezynq.TxLoop`). The ring holds `lead` zero frames (the ENSM keys
  after the DMA starts), the PPDU, silence. Only the span that changed is
  rewritten; the burst ends before the ring wraps, so the PPDU goes out once.
  After the board-side unkey (ENSM -> ALERT) the ENSM is put back in RX.

  Options: `:mcs` (0), `:lead` (8000 frames), `:fs_khz` (ring playback rate,
  4000 at DATA_CLK 16 MHz), `:atten_db` (30.0), `:lo_hz`, `:guard_ms` (2),
  `:ant` (`:tx1`).
  """
  use GenServer
  alias MimoHalow.Halowave

  @ring_frames 131_072
  @loop Nervezynq.TxLoop
  @tone Nervezynq.TxTone
  @sdr Nervezynq.SDR

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Transmit `psdu` (FCS added here). Returns timing or an error."
  def send(s \\ __MODULE__, psdu, opts \\ []), do: GenServer.call(s, {:send, psdu, opts}, 10_000)
  def stats(s \\ __MODULE__), do: GenServer.call(s, :stats)

  @impl true
  def init(opts) do
    st = %{
      mcs: Keyword.get(opts, :mcs, 0),
      lead: Keyword.get(opts, :lead, 8000),
      fs: Keyword.get(opts, :fs_khz, 4000),
      atten: Keyword.get(opts, :atten_db, 30.0),
      guard: Keyword.get(opts, :guard_ms, 2),
      ant: Keyword.get(opts, :ant, :tx1),
      prev: 0,
      setup_done: false,
      n: %{sent: 0, errors: 0, last: nil}
    }

    :ok = ok(Halowave.load())
    if lo = opts[:lo_hz], do: {:ok, _} = @tone.set_tx_lo(lo)
    # Clean ring once: zero lead + any stale image.
    @loop.dma_stop()
    :ok = @loop.dma_write(:binary.copy(<<0>>, 8 * @ring_frames), 0)
    {:ok, st}
  end

  defp ok(:ok), do: :ok
  defp ok({:error, {:reload, _}}), do: :ok
  defp ok({:error, {:upgrade, _}}), do: :ok
  defp ok(e), do: e

  @impl true
  def handle_call(:stats, _, st), do: {:reply, st.n, st}

  def handle_call({:send, psdu, opts}, _, st) do
    mcs = Keyword.get(opts, :mcs, st.mcs)
    t0 = System.monotonic_time(:microsecond)

    with {:ok, fr} <- Halowave.frames_wire(Halowave.with_fcs(psdu), mcs, st.ant),
         nfr = div(byte_size(fr), 8),
         true <- st.lead + nfr < @ring_frames || {:error, :ppdu_too_long},
         ms = div(st.lead + nfr + st.fs - 1, st.fs) + st.guard,
         true <- ms * st.fs < @ring_frames || {:error, {:burst_wraps, ms}} do
      t1 = System.monotonic_time(:microsecond)
      @loop.dma_stop()
      tail = max(st.prev - nfr, 0)
      :ok = @loop.dma_write_wire(fr <> :binary.copy(<<0>>, 8 * tail), 8 * st.lead)
      t2 = System.monotonic_time(:microsecond)

      # Synchronous key/sleep/unkey in this process: no concurrent SPI.
      # First packet: full dma_key (one-time setup), then set the attenuation
      # once, since its unkey parks it at 89.75 dB. Later packets: dma_key_fast,
      # which leaves the attenuation alone (TX is off outside ENSM TX anyway).
      r =
        if st.setup_done do
          case @loop.dma_key_fast(ms) do
            {:ok, %{key: {:ok, _}}} -> :ok
            e -> e
          end
        else
          case @loop.dma_key(ms, atten_db: st.atten, setup: true) do
            {:ok, %{key: {:ok, _}}} ->
              {:ok, _} = @tone.set_tx_atten(st.atten)
              :ok

            e ->
              e
          end
        end

      {:ok, _} = @sdr.enable(:rx)
      t3 = System.monotonic_time(:microsecond)
      res = %{mcs: mcs, frames: nfr, burst_ms: ms, gen_us: t1 - t0, write_us: t2 - t1, air_us: t3 - t2, key: r}
      ok? = r == :ok
      n = %{st.n | sent: st.n.sent + if(ok?, do: 1, else: 0), errors: st.n.errors + if(ok?, do: 0, else: 1), last: res}
      {:reply, if(ok?, do: {:ok, res}, else: {:error, res}), %{st | prev: nfr, n: n, setup_done: st.setup_done or ok?}}
    else
      {:error, _} = e -> {:reply, e, %{st | n: %{st.n | errors: st.n.errors + 1}}}
    end
  end
end
