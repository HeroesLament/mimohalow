defmodule MimoHalow.Model.Scrambler do
  @moduledoc """
  802.11 scrambler, generator x^7 + x^4 + 1. State is a 7-bit integer with
  bit k-1 holding register cell x_k; each step outputs x7 xor x4 and shifts
  it into x1.
  """
  import Bitwise

  @doc "`n` sequence bits from `state`; returns `{bits, state}`."
  def sequence(n, state) do
    {bits, s} =
      Enum.reduce(1..n//1, {[], state &&& 0x7F}, fn _, {acc, s} ->
        f = bxor(s >>> 6, s >>> 3) &&& 1
        {[f | acc], (s <<< 1 &&& 0x7F) ||| f}
      end)

    {Enum.reverse(bits), s}
  end

  @doc "Scramble (or descramble) `bits` from `state`."
  def scramble(bits, state) do
    {seq, _} = sequence(length(bits), state)
    Enum.zip_with(bits, seq, &bxor/2)
  end
end
