defmodule MimoHalow.RNS.Interface do
  @moduledoc """
  Reticulum interface over the HaLow PHY: one RNS packet per PPDU.

  TX: `{:inbound, packet, _}` from the stack -> `MimoHalow.Tx.send/2` with
  the raw packet as PSDU (FCS added by Tx), after 0..`:jitter_ms` of random
  delay so nodes rebroadcasting the same announce do not key together.
  RX: `{:mimohalow_rx, psdu, sig}` from `MimoHalow.Rx` (FCS checked and
  stripped) -> `RNS.PacketHandler`.

  Reuses running `MimoHalow.Rx` / `MimoHalow.Tx` processes when present,
  otherwise starts them linked. Params (string keys, as RNS config):
  "mcs", "atten_db", "lo_hz", "jitter_ms", "name", "fabric" (TX through the
  PHY's transmitter, `MimoHalow.Tx` `fabric: true`).
  """
  use GenServer, restart: :permanent
  require Logger

  @mtu 500

  def start(params, transport), do: GenServer.start(__MODULE__, {params, transport}, name: __MODULE__)
  def start_link(params, transport), do: GenServer.start_link(__MODULE__, {params, transport}, name: __MODULE__)
  def stats, do: GenServer.call(__MODULE__, :stats)

  def interface_spec do
    RNS.InterfaceSpec.new("MimoHalow", __MODULE__, [], ["mcs", "atten_db", "lo_hz", "jitter_ms", "name", "fabric"])
  end

  @impl true
  def init({params, transport}) do
    mcs = Map.get(params, "mcs", 0)

    unless Process.whereis(MimoHalow.Tx) do
      tx_opts = [mcs: mcs, atten_db: Map.get(params, "atten_db", 30.0), fabric: Map.get(params, "fabric", false)]
      tx_opts = if lo = params["lo_hz"], do: [{:lo_hz, lo} | tx_opts], else: tx_opts
      {:ok, _} = MimoHalow.Tx.start_link(tx_opts)
    end

    case Process.whereis(MimoHalow.Rx) do
      nil -> {:ok, _} = MimoHalow.Rx.start_link(bus: MimoHalow.Bus.Nervezynq, subscriber: self())
      _ -> :ok = MimoHalow.Rx.subscribe(self())
    end

    id = Map.get(params, "name", "MimoHalow@#{node()}")
    iface = RNS.Interface.new(id, self(), mode: :full)
    RNS.InterfaceManager.interface_started(iface)

    {:ok,
     %{iface: iface, transport: transport, mcs: mcs, jitter: Map.get(params, "jitter_ms", 40),
       n: %{tx: 0, tx_err: 0, tx_too_big: 0, rx: 0, last_tx: nil, last_rx: nil}}}
  end

  @impl true
  def handle_call(:stats, _, st), do: {:reply, st.n, st}

  @impl true
  def handle_info({:inbound, packet, _src}, st) do
    raw = RNS.Packet.raw(packet) || RNS.Packet.raw(RNS.Packet.generate_raw(packet))

    n =
      if byte_size(raw) > @mtu do
        %{st.n | tx_too_big: st.n.tx_too_big + 1}
      else
        if st.jitter > 0, do: Process.sleep(:rand.uniform(st.jitter))

        case MimoHalow.Tx.send(MimoHalow.Tx, raw, mcs: st.mcs) do
          {:ok, r} -> %{st.n | tx: st.n.tx + 1, last_tx: {byte_size(raw), r.burst_ms}}
          e ->
            Logger.warning("MimoHalow TX failed: #{inspect(e)}")
            %{st.n | tx_err: st.n.tx_err + 1}
        end
      end

    {:noreply, %{st | n: n}}
  end

  def handle_info({:mimohalow_rx, psdu, _sig}, st) do
    RNS.PacketHandler.start(fn -> {:ok, psdu} end, st.iface, st.transport)
    {:noreply, %{st | n: %{st.n | rx: st.n.rx + 1, last_rx: byte_size(psdu)}}}
  end

  def handle_info({:transport_change, t}, st), do: {:noreply, %{st | transport: t}}
  def handle_info(_, st), do: {:noreply, st}
end
