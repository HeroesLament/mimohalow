defmodule MimoHalow.Hw.Rx.CpeTest do
  use ExUnit.Case
  import Bitwise
  alias MimoHalow.Model.Fixed.Cpe
  alias MimoHalow.Model.S1g.Params
  alias MimoHalow.Test.Cosim

  @bw 2
  @data_k Params.data(@bw)
  @pilot_k Params.pilots(@bw)
  # tone -> {pilot?, index}, in FFT output order
  @order (
           idx = Map.merge(
             @data_k |> Enum.with_index() |> Map.new(fn {k, d} -> {Params.bin(k, 2), {0, d}} end),
             @pilot_k |> Enum.with_index() |> Map.new(fn {k, d} -> {Params.bin(k, 2), {1, d}} end)
           )

           for p <- 0..63, b = Cosim.bitrev6(p), Map.has_key?(idx, b), do: idx[b]
         )

  test "Fixed.Cpe rotator copy == Hw.RotTab.model" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..2000 do
      x = :rand.uniform(1 <<< 25) - (1 <<< 24)
      y = :rand.uniform(1 <<< 25) - (1 <<< 24)
      a = :rand.uniform(65_536) - 32_769
      assert Cpe.rotate(x, y, a) == Hw.RotTab.model(x, y, a)
    end
  end

  test "Fixed.Cpe atan2 tracks the true angle" do
    for t <- [-0.49, -0.3, -0.1, 0.0, 0.05, 0.25, 0.4999] do
      w = 2 * :math.pi() * t
      z = Cpe.atan2(round(1.0e6 * :math.sin(w)), round(1.0e6 * :math.cos(w)))
      assert abs(Cpe.wrap(z - round(t * 65_536), 16)) < 8
    end
  end

  # Per symbol: tones in FFT order, D = c G x e^{j phi_j}; x the pilot value or QPSK.
  defp symbols(nsym, seed) do
    :rand.seed(:exsss, {seed, 9, 4})

    for j <- 0..(nsym - 1) do
      phi = (:rand.uniform() - 0.5) * 6.0

      tones =
        for {pil, i} <- @order do
          g = 20_000 + :rand.uniform(900_000)
          x = if pil == 1, do: (if Cpe.pilot_neg?(@bw, i, j), do: {-1.0, 0.0}, else: {1.0, 0.0}), else: {Enum.random([-1, 1]) * 0.7, Enum.random([-1, 1]) * 0.7}
          {xr, xi} = x
          {c, s} = {:math.cos(phi), :math.sin(phi)}
          k = 8.0 * g
          {pil, i, round(k * (xr * c - xi * s)) + :rand.uniform(2000) - 1000, round(k * (xr * s + xi * c)) + :rand.uniform(2000) - 1000, g}
        end

      # one saturation edge per symbol on a data tone
      tones = List.update_at(tones, 5, fn {0, d, _, di, g} -> {0, d, -(1 <<< 24), di, g}; t -> t end)
      {j, phi, tones}
    end
  end

  @tag :iverilog
  test "emitted Verilog == Fixed.Cpe (SIG and data symbols, wrapping phases, sat edge)" do
    syms = symbols(9, 5)

    stim =
      for {j, _phi, tones} <- syms, {{pil, i, dr, di, g}, n} <- Enum.with_index(tones) do
        last = if n == length(tones) - 1, do: 1, else: 0
        "#{j} #{i} #{pil} #{last} #{Cosim.hex(dr, 26)} #{Cosim.hex(di, 26)} #{g}"
      end

    got =
      Cosim.run([MimoHalow.Hw.Rx.Cpe], "tb_cpe.v", stim)
      |> Enum.map(fn l ->
        [j, d, re, im, g, last, th] = String.split(l)
        {String.to_integer(j), String.to_integer(d), Cosim.shex(re, 27), Cosim.shex(im, 27), String.to_integer(g),
         String.to_integer(last), String.to_integer(th)}
      end)

    want =
      Enum.flat_map(syms, fn {j, _phi, tones} ->
        {th, out} = Cpe.symbol(@bw, j, tones)
        n = length(out)
        Enum.map(Enum.with_index(out), fn {{d, xo, yo, g}, ix} -> {j, d, xo, yo, g, if(ix == n - 1, do: 1, else: 0), th &&& 0xFFFF} end)
      end)

    assert length(got) == length(want)
    assert got == want

    # and the phase is the one applied
    for {j, phi, tones} <- syms do
      {th, _} = Cpe.symbol(@bw, j, tones)
      err = Cpe.wrap(th - round(phi / (2 * :math.pi()) * 65_536), 16)
      assert abs(err) < 200, "symbol #{j}: theta off by #{err}/65536 turn"
    end
  end
end
