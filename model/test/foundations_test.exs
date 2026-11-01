defmodule MimoHalow.Model.FoundationsTest do
  use ExUnit.Case, async: true
  alias MimoHalow.Model.{Bcc, Cx, Fft, Mat2, Qam, Scrambler}
  alias MimoHalow.Model.Mimo.Channel

  defp close?({a, b}, {c, d}, tol \\ 1.0e-9), do: abs(a - c) < tol and abs(b - d) < tol

  test "802.11 scrambler sequence from the all-ones state (17.3.5.5)" do
    want =
      "00001110 11110010 11001001 00000010 00100110 00101110 10110110 00001100 11010100 11100111 10110100 00101010 11111010 01010001 10111000 1111111"
      |> String.replace(" ", "")
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)

    {got, state} = Scrambler.sequence(127, 0x7F)
    assert got == want
    assert state == 0x7F
  end

  test "scramble is an involution" do
    bits = for i <- 1..200, do: rem(i * 7 + 3, 5) |> rem(2)
    assert bits |> Scrambler.scramble(0x5D) |> Scrambler.scramble(0x5D) == bits
  end

  test "BCC impulse response is g0 / g1 interleaved" do
    out = Bcc.encode([1, 0, 0, 0, 0, 0, 0])
    {a, b} = out |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1) |> Enum.unzip()
    assert a == [1, 0, 1, 1, 0, 1, 1]
    assert b == [1, 1, 1, 1, 0, 0, 1]
  end

  test "BCC Viterbi corrects errors in soft input" do
    {info, _} = Channel.bits(Channel.rng(7), 300)
    coded = Bcc.encode(info ++ List.duplicate(0, 6))
    llr = Enum.map(coded, &if(&1 == 0, do: 2.0, else: -2.0))
    flipped = llr |> Enum.with_index() |> Enum.map(fn {l, i} -> if rem(i, 37) == 5, do: -l, else: l end)
    assert Bcc.viterbi(flipped, terminated: true) == info ++ List.duplicate(0, 6)
  end

  test "constellations: unit energy, Gray neighbours on each axis" do
    for mod <- Qam.mods() do
      pts = Qam.constellation(mod)
      e = Enum.sum(Enum.map(pts, fn {_, p} -> Cx.abs2(p) end)) / length(pts)
      assert abs(e - 1.0) < 1.0e-12, "#{mod} energy #{e}"
    end

    pts = Qam.constellation(:qam64)
    k = Qam.k_mod(:qam64)

    for {b1, {i1, q1}} <- pts, {b2, {i2, q2}} <- pts,
        abs(abs(i1 - i2) + abs(q1 - q2) - 2 * k) < 1.0e-9 do
      assert Enum.zip_with(b1, b2, &if(&1 == &2, do: 0, else: 1)) |> Enum.sum() == 1
    end
  end

  test "802.11 16-QAM I levels: 00 -3, 01 -1, 11 +1, 10 +3" do
    k = Qam.k_mod(:qam16)
    for {b, l} <- [{[0, 0], -3}, {[0, 1], -1}, {[1, 1], 1}, {[1, 0], 3}] do
      {i, _} = Qam.point(b ++ [0, 0], :qam16)
      assert abs(i - l * k) < 1.0e-12
    end
  end

  test "FFT round trip and impulse" do
    xs = for k <- 0..63, do: Cx.new(:math.sin(k * 0.3), :math.cos(k * 1.7))
    assert Enum.zip_with(Fft.ifft(Fft.fft(xs)), xs, &close?/2) |> Enum.all?()
    imp = [Cx.new(1.0) | List.duplicate(Cx.zero(), 31)]
    assert Enum.all?(Fft.fft(imp), &close?(&1, Cx.new(1.0)))
  end

  test "2x2 inverse and SVD reconstruct random channels" do
    {_, rng} =
      Enum.reduce(1..200, {nil, Channel.rng(3)}, fn _, {_, rng} ->
        {h, rng} = Channel.rayleigh2(rng)
        {{a, b}, {c, d}} = Mat2.mul(h, Mat2.inv(h))
        assert close?(a, Cx.new(1.0), 1.0e-9) and close?(d, Cx.new(1.0), 1.0e-9)
        assert close?(b, Cx.zero(), 1.0e-9) and close?(c, Cx.zero(), 1.0e-9)

        {u, {s1, s2}, v} = Mat2.svd(h)
        assert s1 >= s2
        s = {{Cx.new(s1), Cx.zero()}, {Cx.zero(), Cx.new(s2)}}
        {{a, b}, {c, d}} = u |> Mat2.mul(s) |> Mat2.mul(Mat2.herm(v))
        {{e, f}, {g, i}} = h
        assert close?(a, e, 1.0e-9) and close?(b, f, 1.0e-9) and close?(c, g, 1.0e-9) and close?(d, i, 1.0e-9)
        {nil, rng}
      end)

    assert rng
  end
end
