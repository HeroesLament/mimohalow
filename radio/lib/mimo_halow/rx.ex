defmodule MimoHalow.Rx do
  @moduledoc """
  Polls the RX ring through a `MimoHalow.Bus` and sends each complete frame
  with a good FCS to the subscriber as `{:mimohalow_rx, psdu_without_fcs, sig}`.

  Options: `:bus` (module), `:subscriber` (pid), `:interval_ms` (default 5).
  """
  use GenServer
  alias MimoHalow.RxRing

  @win 0x10000
  @wc @win + 4
  @ring @win + 4 * 2048

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  def stats(s \\ __MODULE__), do: GenServer.call(s, :stats)
  def subscribe(s \\ __MODULE__, pid), do: GenServer.call(s, {:subscribe, pid})

  @impl true
  def init(opts) do
    bus = Keyword.fetch!(opts, :bus)
    st = %{
      bus: bus,
      sub: Keyword.get(opts, :subscriber),
      every: Keyword.get(opts, :interval_ms, 5),
      ring: %RxRing{wc: bus.read32(@wc)},
      n: %{frames: 0, good: 0, bad_fcs: 0, partial: 0, lost_words: 0, polls: 0}
    }
    {:ok, st, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, st), do: {:noreply, poll(st)}

  @impl true
  def handle_info(:poll, st), do: {:noreply, poll(st)}

  @impl true
  def handle_call(:stats, _, st), do: {:reply, Map.put(st.n, :wc, st.ring.wc), st}
  def handle_call({:subscribe, pid}, _, st), do: {:reply, :ok, %{st | sub: pid}}

  defp poll(%{bus: bus, ring: ring} = st) do
    wc = bus.read32(@wc)
    {lost, spans} = RxRing.spans(ring.wc, wc)
    words = Enum.flat_map(spans, fn {i, n} -> bus.read_window(@ring + 4 * i, n) end)
    ring = if lost > 0, do: %{ring | cur: nil}, else: ring
    {ring, frames} = RxRing.feed(%{ring | wc: wc}, words)

    n = Enum.reduce(frames, %{st.n | lost_words: st.n.lost_words + lost, polls: st.n.polls + 1}, fn f, n ->
      n = %{n | frames: n.frames + 1}
      cond do
        f.fcs_ok ->
          deliver(st.sub, f)
          %{n | good: n.good + 1}
        f.complete -> %{n | bad_fcs: n.bad_fcs + 1}
        true -> %{n | partial: n.partial + 1}
      end
    end)

    Process.send_after(self(), :poll, st.every)
    %{st | ring: ring, n: n}
  end

  defp deliver(nil, _), do: :ok
  defp deliver(pid, %{psdu: p, sig: s}), do: send(pid, {:mimohalow_rx, binary_part(p, 0, byte_size(p) - 4), s})
end
