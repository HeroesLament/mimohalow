defmodule MimoHalow.Model.Fixed.DcBlock do
  @moduledoc """
  DC blocker ahead of Decim4, one 12-bit component at a time; twin of
  `MimoHalow.Hw.Rx.DcBlock`.

  A leaky integrator holds the DC estimate times 2^12 in a signed 24-bit
  accumulator: per sample `d = acc >>> 12`, `y = sat12(x - d)`,
  `acc = wrap24(acc + x - d)`. Time constant 4096 samples (512 us at
  8 MS/s), corner ~310 Hz: far below the 31.25 kHz S1G 2 MHz tone spacing,
  and DC is not an occupied tone.

  Found on the air (2026-11-03, dr-b -> dr-a, 2.412 GHz): ~66 counts of DC
  per chain from the AD9363, as large as the PPDU itself at the bench's
  levels. With it the RTL detected and lost the SIG; with the window mean
  removed the same capture decoded exactly.
  """
  import Bitwise

  @k 12

  def k, do: @k

  @doc "One integer stream -> the blocked stream (same length). `bypass` passes x."
  @spec run([integer()], boolean()) :: [integer()]
  def run(xs, bypass \\ false) do
    {ys, _} =
      Enum.map_reduce(xs, 0, fn x, acc ->
        d = acc >>> @k
        y = if bypass, do: x, else: sat12(x - d)
        {y, wrap24(acc + x - d)}
      end)

    ys
  end

  @doc "Complex helper: [{i, q}] -> [{i, q}]."
  def run_cx(xs, bypass \\ false) do
    Enum.zip(run(Enum.map(xs, &elem(&1, 0)), bypass), run(Enum.map(xs, &elem(&1, 1)), bypass))
  end

  defp sat12(v), do: v |> max(-2048) |> min(2047)

  defp wrap24(v) do
    v = v &&& 0xFF_FFFF
    if v >= 0x80_0000, do: v - 0x100_0000, else: v
  end
end
