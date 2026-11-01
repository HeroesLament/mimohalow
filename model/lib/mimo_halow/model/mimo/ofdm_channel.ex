defmodule MimoHalow.Model.Mimo.OfdmChannel do
  @moduledoc """
  Frequency-selective 2x2 block-fading channel: each of the four antenna
  pairs is an independent `ntaps`-tap Rayleigh channel with an exponential
  power-delay profile of rms delay `rms` samples, total power 1. Returns the
  2x2 frequency response on each requested subcarrier of an `nfft` FFT.

  `data_subcarriers/0` is the 52-tone data set of a 64-point FFT (+-1..28
  less pilots +-7, +-21): the 11n 20 MHz plan, assumed for S1G 2 MHz until
  checked against the standard text.
  """
  alias MimoHalow.Model.{Cx, Mat2}
  alias MimoHalow.Model.Mimo.Channel

  def data_subcarriers do
    for k <- Enum.to_list(-28..-1) ++ Enum.to_list(1..28), k not in [-21, -7, 7, 21], do: k
  end

  def pdp(ntaps, rms) do
    w = for l <- 0..(ntaps - 1), do: if(rms > 0, do: :math.exp(-l / rms), else: if(l == 0, do: 1.0, else: 0.0))
    s = Enum.sum(w)
    Enum.map(w, &(&1 / s))
  end

  @doc "`{[2x2 per subcarrier], rng}`."
  def draw(rng, subcarriers, opts \\ []) do
    nfft = Keyword.get(opts, :nfft, 64)
    p = pdp(Keyword.get(opts, :ntaps, 8), Keyword.get(opts, :rms, 2.0))

    {taps, rng} =
      Enum.map_reduce(1..4, rng, fn _, rng ->
        Enum.map_reduce(p, rng, fn pw, rng -> Channel.cn(rng, pw) end)
      end)

    resp = fn ts, k ->
      ts
      |> Enum.with_index()
      |> Enum.map(fn {t, l} -> Cx.mul(t, Cx.expj(-2 * :math.pi() * k * l / nfft)) end)
      |> Cx.sum()
    end

    [t11, t12, t21, t22] = taps
    hs = for k <- subcarriers, do: {{resp.(t11, k), resp.(t12, k)}, {resp.(t21, k), resp.(t22, k)}}
    {hs, rng}
  end

  def identity_list(n), do: List.duplicate(Mat2.identity(), n)
end
