defmodule MimoHalow.Tx do
  @moduledoc """
  One-PPDU-per-key transmit over the board's cyclic TX DMA ring
  (`Nervezynq.TxLoop`). The ring holds `lead` zero frames (the ENSM keys
  after the DMA starts), the PPDU, silence. Only the span that changed is
  rewritten; the burst ends before the ring wraps, so the PPDU goes out once.
  After the board-side unkey (ENSM -> ALERT) the ENSM is put back in RX.

  Options: `:mcs` (0), `:lead` (8000 frames), `:fs_khz` (ring playback rate,
  4000 at DATA_CLK 16 MHz), `:atten_db` (30.0), `:lo_hz`, `:guard_ms` (2),
  `:ant` (`:tx1`), `:fabric` (false).

  `fabric: true` ("MHW2" bitstreams): the PHY's own transmitter makes the
  samples (`MimoHalow.FabricTx`, CTRL1[14] claimed at start). No PPDU build
  or ring write here: the CTRL3 commands go out once the ENSM is in TX
  (`Nervezynq.TxLoop.phy_key/2`). TX1 only.

  `ensm_pins: true` (the default with `fabric`): the ENSM runs under pin
  control (`TxLoop.pin_mode/1`, CTRL1 ENABLE / TXNRX), so keying is three
  CTRL1 writes each way instead of ~90 ms of SPI (`TxLoop.pin_key/3`). The
  one-time TX setup and the attenuation happen at start, before pin control.
  """
  use GenServer
  alias MimoHalow.{FabricTx, Halowave}

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
      fabric: Keyword.get(opts, :fabric, false),
      pins: Keyword.get(opts, :ensm_pins, Keyword.get(opts, :fabric, false)),
      bus: Keyword.get(opts, :bus, MimoHalow.Bus.Nervezynq),
      prev: 0,
      setup_done: false,
      n: %{sent: 0, errors: 0, last: nil}
    }

    :ok = ok(Halowave.load())
    if lo = opts[:lo_hz], do: {:ok, _} = @tone.set_tx_lo(lo)
    if st.fabric do
      true = FabricTx.available?(st.bus) || {:error, :no_fabric_tx}
      :ok = FabricTx.claim(st.bus, true)
    end

    st =
      if st.fabric and st.pins do
        # Out of pin control first (a restart finds the board in it), then
        # dma_key's one-time setup (TX data delay, BIST and loopback off) with
        # the PHY on the port, the attenuation once, then pin control.
        {:ok, _} = @loop.pin_mode(false)
        {:ok, _} = @loop.dma_key(1, atten_db: st.atten, setup: true)
        {:ok, _} = @tone.set_tx_atten(st.atten)
        {:ok, %{state: :rx}} = @loop.pin_mode(true)
        %{st | setup_done: true}
      else
        st
      end

    if not st.fabric do
      # Clean ring once: zero lead + any stale image.
      @loop.dma_stop()
      :ok = @loop.dma_write(:binary.copy(<<0>>, 8 * @ring_frames), 0)
    end

    {:ok, st}
  end

  defp ok(:ok), do: :ok
  defp ok({:error, {:reload, _}}), do: :ok
  defp ok({:error, {:upgrade, _}}), do: :ok
  defp ok(e), do: e

  @impl true
  def handle_call(:stats, _, st), do: {:reply, st.n, st}

  def handle_call({:send, psdu, opts}, _, %{fabric: true} = st) do
    mcs = Keyword.get(opts, :mcs, st.mcs)
    t0 = System.monotonic_time(:microsecond)

    with {:ok, ws} <- Halowave.fabric_cmds(Halowave.with_fcs(psdu), mcs) do
      nfr = FabricTx.frames(ws)
      ms = div(nfr + st.fs - 1, st.fs) + st.guard

      # First packet: dma_key's one-time setup (TX data delay, BIST and
      # loopback off) with the PHY on the port, then the attenuation once.
      unless st.setup_done do
        {:ok, _} = @loop.dma_key(1, atten_db: st.atten, setup: true)
        {:ok, _} = @tone.set_tx_atten(st.atten)
      end

      t1 = System.monotonic_time(:microsecond)
      start = fn -> FabricTx.start(st.bus, ws, 20) end

      k =
        if st.pins do
          {:ok, k} = @loop.pin_key(start, ms)
          Map.put(k, :key, {:ok, :pins})
        else
          {:ok, k} = @loop.phy_key(start, ms)
          {:ok, _} = @sdr.enable(:rx)
          k
        end

      t2 = System.monotonic_time(:microsecond)
      ok? = match?({:ok, _}, k.key) and k.fun == :ok
      res = %{mcs: mcs, frames: nfr, burst_ms: ms, gen_us: t1 - t0, air_us: t2 - t1, key: k.key, start: k.fun}
      n = %{st.n | sent: st.n.sent + if(ok?, do: 1, else: 0), errors: st.n.errors + if(ok?, do: 0, else: 1), last: res}
      {:reply, if(ok?, do: {:ok, res}, else: {:error, res}), %{st | n: n, setup_done: true}}
    else
      {:error, _} = e -> {:reply, e, %{st | n: %{st.n | errors: st.n.errors + 1}}}
    end
  end

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
