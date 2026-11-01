defmodule MimoHalow.Model.Fft do
  @moduledoc "Radix-2 FFT on lists of `Cx`. `fft` uses e^-j, `ifft` e^+j and 1/N."
  alias MimoHalow.Model.Cx

  def fft(xs), do: run(xs, -1.0)

  def ifft(xs) do
    n = length(xs)
    xs |> run(1.0) |> Enum.map(&Cx.scale(&1, 1.0 / n))
  end

  defp run([x], _sign), do: [x]

  defp run(xs, sign) do
    n = length(xs)
    {ev, od} = xs |> Enum.chunk_every(2) |> Enum.map(fn [a, b] -> {a, b} end) |> Enum.unzip()
    e = run(ev, sign)
    o = run(od, sign)

    tw =
      o
      |> Enum.with_index()
      |> Enum.map(fn {x, k} -> Cx.mul(Cx.expj(sign * 2 * :math.pi() * k / n), x) end)

    Enum.zip_with(e, tw, &Cx.add/2) ++ Enum.zip_with(e, tw, &Cx.sub/2)
  end
end
