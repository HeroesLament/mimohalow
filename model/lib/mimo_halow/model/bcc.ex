defmodule MimoHalow.Model.Bcc do
  @moduledoc """
  802.11 binary convolutional code, K = 7, g0 = 133o, g1 = 171o, rate 1/2,
  output order A0 B0 A1 B1 ... Encoder window bit 6 is the current input,
  bits 5..0 the delays d1..d6. Viterbi takes LLRs as log P(0)/P(1).
  """
  import Bitwise

  @g0 0o133
  @g1 0o171
  @nstates 64

  def encode(bits, state \\ 0) do
    {out, _} =
      Enum.reduce(bits, {[], state}, fn u, {acc, s} ->
        w = u <<< 6 ||| s
        {[parity(w &&& @g1), parity(w &&& @g0) | acc], w >>> 1}
      end)

    Enum.reverse(out)
  end

  @doc """
  Soft Viterbi over `llrs` (pairs A, B). With `terminated: true` the trellis
  must end in state 0 (six tail zeros included in the input).
  """
  def viterbi(llrs, opts \\ []) do
    inf = 1.0e300
    start = Tuple.duplicate(inf, @nstates) |> put_elem(0, 0.0)

    {metric, decisions} =
      llrs
      |> Enum.chunk_every(2)
      |> Enum.reduce({start, []}, fn [la, lb], {m, ds} ->
        {m2, d} = step(m, la, lb, inf)
        {m2, [d | ds]}
      end)

    final =
      if Keyword.get(opts, :terminated, false) do
        0
      else
        0..(@nstates - 1) |> Enum.min_by(&elem(metric, &1))
      end

    traceback(decisions, final, [])
  end

  # Next state s2 = (u << 5) | (s >> 1); its two predecessors are
  # s = ((s2 << 1) & 63) | b for b in 0..1, with input u = s2 >> 5.
  defp step(m, la, lb, inf) do
    cols =
      for s2 <- 0..(@nstates - 1) do
        u = s2 >>> 5

        [c0, c1] =
          for b <- 0..1 do
            s = (s2 <<< 1 &&& 63) ||| b
            pm = elem(m, s)

            if pm >= inf do
              inf
            else
              w = u <<< 6 ||| s
              pm + cost(parity(w &&& @g0), la) + cost(parity(w &&& @g1), lb)
            end
          end

        if c1 < c0, do: {c1, 1}, else: {c0, 0}
      end

    {cols |> Enum.map(&elem(&1, 0)) |> List.to_tuple(), cols |> Enum.map(&elem(&1, 1)) |> List.to_tuple()}
  end

  defp traceback([], _s, acc), do: acc

  defp traceback([d | ds], s2, acc) do
    b = elem(d, s2)
    traceback(ds, (s2 <<< 1 &&& 63) ||| b, [s2 >>> 5 | acc])
  end

  defp cost(1, llr), do: llr
  defp cost(0, _llr), do: 0.0

  defp parity(x), do: x |> Integer.digits(2) |> Enum.sum() |> band(1)
end
