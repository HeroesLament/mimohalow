defmodule MimoHalow.FabricTx do
  @moduledoc """
  Transmit through the PHY's own transmitter (`MimoHalow.Hw.Tx.TxPhy` in
  PhyHost, "MHW2" bitstreams): the PSDU and its SIG / rate parameters go to
  CTRL3 as commands (`MimoHalow.Halowave.fabric_cmds/2`); the fabric makes
  the 8 MS/s samples on the TX port (I1/Q1; I2/Q2 zero).

  CTRL1[14] gives the PHY the TX port (`claim/2`). Keying the AD9363
  (ENABLE / TXNRX) stays with the caller, as on the TX DMA path. Never run
  this beside another process that touches the AD9363's SPI.
  """
  import Bitwise
  alias MimoHalow.Halowave

  @ctrl1 0x10
  @ctrl3 0x18
  @win 0x10000
  @id 0x4D485732

  @doc "True when the loaded bitstream has the fabric transmitter."
  def available?(bus), do: bus.read32(@win) == @id

  @doc "Give the TX port to the PHY (`true`) or back to the top's paths."
  def claim(bus, on \\ true) do
    c = bus.read32(@ctrl1)
    bus.write32(@ctrl1, if(on, do: c ||| 1 <<< 14, else: c &&& bnot(1 <<< 14)))
  end

  @doc "Window word 4: busy, frames sent (mod 128), underruns (saturating at 255)."
  def status(bus) do
    w = bus.read32(@win + 16)
    %{busy: (w &&& 1) == 1, frames: w >>> 1 &&& 0x7F, underruns: w >>> 8 &&& 0xFF}
  end

  @doc """
  Queue one PPDU: waits up to `timeout_ms` for the previous frame to finish,
  then writes the commands (the last one starts the frame). Returns `:ok`,
  `{:error, :busy}` or the NIF's `{:error, reason}`.
  """
  def send(bus, psdu, mcs, timeout_ms \\ 50) do
    with {:ok, ws} <- Halowave.fabric_cmds(psdu, mcs), do: start(bus, ws, timeout_ms)
  end

  @doc "`send/4` with the command words already built (`Halowave.fabric_cmds/2`)."
  def start(bus, words, timeout_ms \\ 50) do
    with :ok <- wait_idle(bus, System.monotonic_time(:millisecond) + timeout_ms) do
      bus.write_fifo(@ctrl3, words)
    end
  end

  @doc """
  TX port samples of the PPDU the command words describe (8 MS/s design rate:
  320 preamble + 160 SIG + 80 per data symbol at the base rate, x4, + 130 from
  the interpolator's filter tails).
  """
  def frames(words), do: 4 * (480 + 80 * (hd(words) &&& 0x3FF)) + 130

  @doc "Block until the current frame has left the TX port (or `timeout_ms`)."
  def wait_done(bus, timeout_ms \\ 50), do: wait_idle(bus, System.monotonic_time(:millisecond) + timeout_ms)

  defp wait_idle(bus, deadline) do
    cond do
      not status(bus).busy -> :ok
      System.monotonic_time(:millisecond) > deadline -> {:error, :busy}
      true -> wait_idle(bus, deadline)
    end
  end
end
