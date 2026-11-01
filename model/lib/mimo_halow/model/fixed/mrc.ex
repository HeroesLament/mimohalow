defmodule MimoHalow.Model.Fixed.Mrc do
  @moduledoc """
  Bit-exact integer model of the MIMO receive stage shared by `:siso`,
  `:mrc_1x2` and `:eigen_1ss` (RTL: `MimoHalow.Hw.Rx.MrcCombiner`): the
  OcuSync `EqFixed` estimator / equaliser arithmetic generalised to N
  receive chains. With a beamformed LTF the estimate is directly the
  effective channel `H v`, so the same block receives eig1.

  Division-free, as `EqFixed`: per subcarrier the combiner emits
  `D = sum_r Y_r conj(H_r)` and `G = sum_r |H_r|^2`; the point is `D / G`
  and its noise variance `sigma^2 / G` (equal sigma^2 per chain).

  1. **Scale** (LTF1, over all chains and tones):
     `sh = max(0, bitlen(OR |L1r|, |L1i|) - 16)`; one shift for every chain,
     so the per-chain products stay commensurate when summed.
  2. **Channel** (LTF2): `Hn = sat18(((L1 + L2) s_k) >> sh)` per chain (2 H
     in FFT units for an LTF of amplitude 1), `dn = sat18((L1 - L2) >> sh)`,
     `noise = (sum_r sum_k |dn|^2) >> log2(chains)`: per-chain units, as the
     single-chain demapper expects.
  3. **Per symbol**: `Yn = sat25(Y >> sh)`; per chain
     `D_r = sat24((Yn conj(Hn)) >> 16)`, `G_r = |Hn|^2 >> 16`;
     `D = sat25(sum D_r)`, `G = sum G_r` (21 bits for two chains).

  Complex values are `{re, im}` integer tuples; per-chain inputs are maps
  `%{tone => {re, im}}`. Shifts are arithmetic (floor).
  """
  import Bitwise

  @doc "Estimate from the two LTF repetitions. `sign`: `%{tone => +1 | -1}`."
  def estimate(ltf1s, ltf2s, tones, sign) do
    mx =
      for l1 <- ltf1s, k <- tones, reduce: 0 do
        acc ->
          {a, b} = Map.fetch!(l1, k)
          acc ||| abs(a) ||| abs(b)
      end

    sh = max(0, bitlen(mx) - 16)

    per_chain =
      for {l1, l2} <- Enum.zip(ltf1s, ltf2s) do
        for k <- tones, into: %{} do
          {a1, b1} = Map.fetch!(l1, k)
          {a2, b2} = Map.fetch!(l2, k)
          s = Map.fetch!(sign, k)
          h = {sat((a1 + a2) * s >>> sh, 18), sat((b1 + b2) * s >>> sh, 18)}
          dn = {sat((a1 - a2) >>> sh, 18), sat((b1 - b2) >>> sh, 18)}
          {k, {h, dn}}
        end
      end

    noise =
      Enum.sum(for c <- per_chain, {_k, {_h, {x, y}}} <- c, do: x * x + y * y) >>> log2(length(ltf1s))

    %{sh: sh, h: Enum.map(per_chain, fn c -> Map.new(c, fn {k, {h, _}} -> {k, h} end) end), noise: noise}
  end

  @doc "Combine one symbol: `ys` per chain. Returns `%{tone => {{d_re, d_im}, g}}`."
  def combine(%{sh: sh, h: hs}, ys, tones) do
    for k <- tones, into: %{} do
      {ds, gs} =
        Enum.zip(hs, ys)
        |> Enum.map(fn {h, y} ->
          {hr, hi} = Map.fetch!(h, k)
          {yr, yi} = Map.fetch!(y, k)
          yr = sat(yr >>> sh, 25)
          yi = sat(yi >>> sh, 25)
          d = {sat((yr * hr + yi * hi) >>> 16, 24), sat((yi * hr - yr * hi) >>> 16, 24)}
          {d, (hr * hr + hi * hi) >>> 16}
        end)
        |> Enum.unzip()

        d = Enum.reduce(ds, {0, 0}, fn {a, b}, {x, y} -> {x + a, y + b} end)
        {k, {{sat(elem(d, 0), 25), sat(elem(d, 1), 25)}, Enum.sum(gs)}}
    end
  end

  def sat(v, bits) do
    hi = (1 <<< (bits - 1)) - 1
    v |> min(hi) |> max(-hi - 1)
  end

  defp bitlen(0), do: 0
  defp bitlen(m), do: length(Integer.digits(m, 2))

  defp log2(1), do: 0
  defp log2(2), do: 1
  defp log2(4), do: 2
end
