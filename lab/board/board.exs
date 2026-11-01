defmodule MimoHalow.Lab.Board do
  @moduledoc """
  Board side of the mimohalow bench tooling. Compiled on the board from
  source by `MimoHalow.Lab.Session.install/1` (no beam shipping, so the
  board's own OTP/Elixir compiles it). Calls the nervezynq board modules at
  runtime only.

  Tail-window capture: the HPStream writer runs for ~10 ms, then stops; the
  ring then holds the most recent samples contiguously behind the write
  pointer. Valid only if the write pointer moved enough and the window was
  shorter than one ring lap (64 bytes/us at 8 MS/s, 1 MB ring = 16.4 ms),
  both measured here on the board.
  """

  @ring 0x100000
  @bytes_per_us 64
  @guard 4096

  def tail_capture(bytes \\ 262_144) when bytes <= @ring - 65_536 do
    h = Nervezynq.HPStream
    h.setup()
    h.disable()
    h.select(:radio)
    h.clear_flags()
    off0 = h.wptr_offset()
    t0 = System.monotonic_time(:microsecond)
    h.enable()
    Process.sleep(10)
    h.disable()
    t1 = System.monotonic_time(:microsecond)
    off = h.wptr_offset()
    moved = rem(off - off0 + @ring, @ring)
    el = t1 - t0

    cond do
      el * @bytes_per_us >= @ring - 65_536 ->
        {:error, {:lapped, el}}

      moved < bytes + 2 * @guard ->
        {:error, {:short, moved, el}}

      true ->
        st = rem(off - @guard - bytes + 2 * @ring, @ring)
        first = min(bytes, @ring - st)
        {:ok, a} = h.ring_read(st, div(first, 4))

        words =
          if first == bytes do
            a
          else
            {:ok, b} = h.ring_read(0, div(bytes - first, 4))
            a ++ b
          end

        u = h.to_u64(words)
        {:ok, %{u64: u, seq: h.check_seq(u), moved: moved, elapsed_us: el}}
    end
  end

  def rx_on, do: Nervezynq.SDR.enable(:rx)

  def tune(hz) do
    {:ok, t} = Nervezynq.TxTone.set_tx_lo(hz)
    {:ok, r} = Nervezynq.SDR.set_frequency(hz)
    %{tx_hz: t.actual_hz, tx_locked: t.vco_locked, rx_hz: r.frequency}
  end
end
