defmodule MimoHalow.Model.Fixed.VPrecode do
  @moduledoc """
  Bit-exact integer model of the single-stream precoder (`:eigen_1ss`; RTL
  `MimoHalow.Hw.Tx.VPrecoder`). A per-subcarrier table of the steering vector
  `v = (v1, v2)` in Q1.14 (16-bit signed), written by the PS from explicit
  feedback; each mapped point `s` (16-bit) goes out on antenna r as
  `a_r = sat16((s v_r) >> 14)`.

  `table/1` quantises float vectors with the phase normalised so v1 is real
  and non-negative (the 802.11 compressed-feedback convention): a common
  phase is invisible to the receiver, and the normalisation makes the table
  a deterministic function of the channel.
  """
  import Bitwise
  alias MimoHalow.Model.Cx

  @one 1 <<< 14

  @doc "`%{tone => {v1, v2}}` float (unit norm) -> Q1.14 table."
  def table(vs) do
    Map.new(vs, fn {k, {v1, v2}} ->
      a = :math.sqrt(Cx.abs2(v1))
      rot = if a > 1.0e-12, do: Cx.scale(Cx.conj(v1), 1 / a), else: Cx.new(1.0)
      {k, {q(Cx.mul(v1, rot)), q(Cx.mul(v2, rot))}}
    end)
  end

  @doc "Precode one point on subcarrier `k`: `{a1, a2}`."
  def apply(table, k, {sr, si}) do
    {v1, v2} = Map.fetch!(table, k)
    {mul(sr, si, v1), mul(sr, si, v2)}
  end

  defp mul(sr, si, {vr, vi}) do
    {sat16((sr * vr - si * vi) >>> 14), sat16((sr * vi + si * vr) >>> 14)}
  end

  defp q({a, b}), do: {sat16(round(a * @one)), sat16(round(b * @one))}

  defp sat16(v), do: v |> min(32_767) |> max(-32_768)
end
