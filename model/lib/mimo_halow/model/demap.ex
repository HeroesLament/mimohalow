defmodule MimoHalow.Model.Demap do
  @moduledoc """
  Max-log soft demapper for one equalised, unbiased point `x` with effective
  noise variance `nvar`: LLR_k = (min_{s: b_k = 1} |x - s|^2 -
  min_{s: b_k = 0} |x - s|^2) / nvar, i.e. log P(0) / P(1).
  """
  alias MimoHalow.Model.{Cx, Qam}

  def llrs(x, nvar, mod) do
    pts = Qam.constellation(mod)
    n = Qam.nbpsc(mod)
    ds = Enum.map(pts, fn {bits, p} -> {bits, Cx.abs2(Cx.sub(x, p))} end)

    for k <- 0..(n - 1) do
      {d0, d1} =
        Enum.reduce(ds, {:infinity, :infinity}, fn {bits, d}, {d0, d1} ->
          if Enum.at(bits, k) == 0, do: {min(d0, d), d1}, else: {d0, min(d1, d)}
        end)

      (d1 - d0) / nvar
    end
  end
end
