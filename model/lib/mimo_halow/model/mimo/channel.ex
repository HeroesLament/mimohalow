defmodule MimoHalow.Model.Mimo.Channel do
  @moduledoc """
  Flat block-fading channels for one subcarrier: i.i.d. CN(0, 1) entries,
  AWGN of variance `sigma2` per receive antenna. Explicit `:rand` state.
  """
  alias MimoHalow.Model.Cx

  def rng(seed), do: :rand.seed_s(:exsss, {seed, 0x5EED, 0xA11})

  def cn(rng, var \\ 1.0) do
    {a, rng} = :rand.normal_s(rng)
    {b, rng} = :rand.normal_s(rng)
    s = :math.sqrt(var / 2)
    {Cx.new(a * s, b * s), rng}
  end

  @doc "2x2 Rayleigh matrix."
  def rayleigh2(rng) do
    {a, rng} = cn(rng)
    {b, rng} = cn(rng)
    {c, rng} = cn(rng)
    {d, rng} = cn(rng)
    {{{a, b}, {c, d}}, rng}
  end

  @doc "Noise 2-vector of variance `sigma2` per entry."
  def noise2(rng, sigma2) do
    {a, rng} = cn(rng, sigma2)
    {b, rng} = cn(rng, sigma2)
    {{a, b}, rng}
  end

  def bits(rng, n) do
    Enum.map_reduce(1..n//1, rng, fn _, r ->
      {v, r} = :rand.uniform_s(2, r)
      {v - 1, r}
    end)
  end
end
