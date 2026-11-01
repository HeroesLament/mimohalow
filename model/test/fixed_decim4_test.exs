defmodule MimoHalow.Model.Fixed.Decim4Test do
  use ExUnit.Case, async: true
  alias MimoHalow.Model.Fixed.Decim4

  defp db(x), do: 20 * :math.log10(max(x, 1.0e-12))

  test "half-band structure" do
    for {h, q} <- [{Decim4.h1(), 15}, {Decim4.h2(), 17}] do
      c = div(length(h) - 1, 2)
      assert Enum.at(h, c) == Bitwise.bsl(1, q - 1)
      assert h == Enum.reverse(h)
      for {v, k} <- Enum.with_index(h), k != c, rem(k - c, 2) == 0, do: assert(v == 0)
    end
  end

  test "passband flat to 0.875 MHz, alias band rejected from 1.125 MHz" do
    pass = for f <- 0..875_000//25_000, do: db(Decim4.response(f * 1.0))
    assert Enum.max(pass) < 0.1 and Enum.min(pass) > -0.5, inspect(pass)

    # Everything that folds onto the occupied band after decimation by 4.
    stop = for f <- 1_125_000..4_000_000//25_000, do: db(Decim4.response(f * 1.0))
    assert Enum.max(stop) < -50.0, "worst #{Enum.max(stop)} dB"
  end

  test "a 300 kHz tone at 8 MS/s comes out at 2 MS/s with unit gain" do
    xs = for n <- 0..4095, do: round(1500 * :math.cos(2 * :math.pi() * 300_000 * n / 8.0e6))
    ys = Decim4.run(xs) |> Enum.drop(40)
    peak = ys |> Enum.map(&abs/1) |> Enum.max()
    assert_in_delta peak, 1500, 30
  end
end
