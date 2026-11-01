defmodule MimoHalow.Model.Mimo.Precode do
  @moduledoc """
  SVD precoding with transmitter channel knowledge, total power 1.
  `eigen_1ss` steers one stream on the strongest eigenmode; `svd_2ss` sends
  two streams at equal power on both eigenmodes (equal MCS, as the standard).
  """
  alias MimoHalow.Model.{Cx, Mat2}

  @r 1 / :math.sqrt(2)

  def eigen_1ss_tx(h, s) do
    {_u, _s, v} = Mat2.svd(h)
    {v1, v2} = Mat2.col(v, 0)
    {Cx.mul(v1, s), Cx.mul(v2, s)}
  end

  @doc "Returns `{s, nvar}`."
  def eigen_1ss_rx(h, y, sigma2) do
    {u, {s1, _}, _v} = Mat2.svd(h)
    z = Mat2.vdot(Mat2.col(u, 0), y)
    {Cx.scale(z, 1 / s1), sigma2 / (s1 * s1)}
  end

  def svd_2ss_tx(h, {s1, s2}) do
    {_u, _s, v} = Mat2.svd(h)
    Mat2.mulv(v, {Cx.scale(s1, @r), Cx.scale(s2, @r)})
  end

  @doc "Returns `{{x1, x2}, {nv1, nv2}}`."
  def svd_2ss_rx(h, y, sigma2) do
    {u, {a, b}, _v} = Mat2.svd(h)
    z1 = Mat2.vdot(Mat2.col(u, 0), y)
    z2 = Mat2.vdot(Mat2.col(u, 1), y)
    {{Cx.scale(z1, 1 / (a * @r)), Cx.scale(z2, 1 / (b * @r))}, {sigma2 / (a * a / 2), sigma2 / (b * b / 2)}}
  end
end
