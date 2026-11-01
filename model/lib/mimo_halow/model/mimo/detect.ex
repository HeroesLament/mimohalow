defmodule MimoHalow.Model.Mimo.Detect do
  @moduledoc """
  2x2 spatial-multiplexing detectors for `y = h x + n`, `E|n|^2 = sigma2`.
  Streams are unit energy; fold any per-stream power scaling into `h`.
  """
  alias MimoHalow.Model.{Cx, Mat2, Qam}

  @doc """
  Linear MMSE. Returns `{{x1, x2}, {nv1, nv2}}`: the unbiased estimates and
  their effective noise variances (1 / SINR_k).
  """
  def mmse(h, y, sigma2) do
    gi = h |> Mat2.herm() |> Mat2.mul(h) |> Mat2.add_diag(sigma2) |> Mat2.inv()
    {x1, x2} = gi |> Mat2.mul(Mat2.herm(h)) |> Mat2.mulv(y)
    {{{g11, _}, _}, {_, {g22, _}}} = gi
    b1 = 1.0 - sigma2 * g11
    b2 = 1.0 - sigma2 * g22
    {{Cx.scale(x1, 1 / b1), Cx.scale(x2, 1 / b2)}, {(1 - b1) / b1, (1 - b2) / b2}}
  end

  @doc "Hard MMSE decision: bits of stream 1 then stream 2."
  def mmse_bits(h, y, sigma2, mod) do
    {{x1, x2}, _} = mmse(h, y, sigma2)
    Qam.slice(x1, mod) ++ Qam.slice(x2, mod)
  end

  @doc "Exhaustive maximum-likelihood decision over both streams."
  def ml_bits(h, y, mod) do
    {bits, _d} = candidates(h, y, mod) |> Enum.min_by(&elem(&1, 1))
    bits
  end

  @doc "Max-log LLRs, log P(0)/P(1), for every bit of both streams."
  def ml_llrs(h, y, sigma2, mod) do
    cs = candidates(h, y, mod)
    n = 2 * Qam.nbpsc(mod)

    for k <- 0..(n - 1) do
      {d0, d1} =
        Enum.reduce(cs, {:infinity, :infinity}, fn {bits, d}, {d0, d1} ->
          if Enum.at(bits, k) == 0, do: {min(d0, d), d1}, else: {d0, min(d1, d)}
        end)

      (d1 - d0) / sigma2
    end
  end

  defp candidates(h, y, mod) do
    c = Qam.constellation(mod)

    for {b1, p1} <- c, {b2, p2} <- c do
      {b1 ++ b2, Mat2.vnorm2(Mat2.vsub(y, Mat2.mulv(h, {p1, p2})))}
    end
  end
end
