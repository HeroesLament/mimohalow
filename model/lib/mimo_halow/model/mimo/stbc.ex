defmodule MimoHalow.Model.Mimo.Stbc do
  @moduledoc """
  Alamouti 2x2 over two symbol periods on one subcarrier, total transmit
  power 1 per period (each antenna 1/2). Slot 1 sends (s1, s2), slot 2
  (-s2*, s1*).
  """
  alias MimoHalow.Model.{Cx, Mat2}

  @r 1 / :math.sqrt(2)

  def encode(s1, s2) do
    {{Cx.scale(s1, @r), Cx.scale(s2, @r)},
     {Cx.scale(Cx.neg(Cx.conj(s2)), @r), Cx.scale(Cx.conj(s1), @r)}}
  end

  @doc "Combine both slots. Returns `{s1, s2, nvar}` (unbiased estimates)."
  def decode({{h11, h12}, {h21, h22}} = h, {y11, y12}, {y21, y22}, sigma2) do
    g = Mat2.frob2(h)

    s1 =
      Cx.sum([
        Cx.mul(Cx.conj(h11), y11),
        Cx.mul(h12, Cx.conj(y21)),
        Cx.mul(Cx.conj(h21), y12),
        Cx.mul(h22, Cx.conj(y22))
      ])

    s2 =
      Cx.sum([
        Cx.mul(Cx.conj(h12), y11),
        Cx.neg(Cx.mul(h11, Cx.conj(y21))),
        Cx.mul(Cx.conj(h22), y12),
        Cx.neg(Cx.mul(h21, Cx.conj(y22)))
      ])

    k = 1 / (g * @r)
    {Cx.scale(s1, k), Cx.scale(s2, k), 2 * sigma2 / g}
  end
end
