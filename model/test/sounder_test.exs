defmodule MimoHalow.Model.SounderTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias MimoHalow.Model.{Cx, Sounder}
  alias MimoHalow.Model.Mimo.Channel

  @fs 8.0e6

  # h[rx][tx] as tap lists.
  @taps [
    [[{0.9, 0.1}, {0.0, 0.3}, {-0.1, 0.05}, {0.02, 0.0}], [{0.2, -0.4}, {0.1, 0.1}, {0.0, -0.05}, {0.0, 0.0}]],
    [[{-0.3, 0.5}, {0.2, 0.0}, {0.05, 0.05}, {0.0, 0.01}], [{0.7, 0.2}, {-0.2, 0.1}, {0.0, 0.0}, {0.03, -0.02}]]
  ]

  defp tx(periods) do
    one = Sounder.period_samples()
    all = List.duplicate(one, periods) |> List.flatten()
    {Enum.map(all, &elem(&1, 0)) |> List.to_tuple(), Enum.map(all, &elem(&1, 1)) |> List.to_tuple()}
  end

  defp channel({x1, x2}, offset, n, cfo_hz, snr_db, seed) do
    sig_p = 400.0 * 400.0
    sigma2 = sig_p * :math.pow(10, -snr_db / 10)
    xs = [x1, x2]

    {rows, _} =
      Enum.map_reduce(@taps, Channel.rng(seed), fn row, rng ->
        Enum.map_reduce(0..(n - 1), rng, fn i, rng ->
          m = i + offset

          s =
            Cx.sum(
              for {taps, x} <- Enum.zip(row, xs), {{a, b}, l} <- Enum.with_index(taps), m - l >= 0 do
                Cx.mul({a, b}, elem(x, m - l))
              end
            )

          {nz, rng} = Channel.cn(rng, sigma2)
          {Cx.add(Cx.mul(s, Cx.expj(2 * :math.pi() * cfo_hz / @fs * i)), nz), rng}
        end)
      end)

    rows |> Enum.map(&List.to_tuple/1) |> List.to_tuple()
  end

  defp h_true(rx, tx, k) do
    @taps
    |> Enum.at(rx)
    |> Enum.at(tx)
    |> Enum.with_index()
    |> Enum.map(fn {t, l} -> Cx.mul(t, Cx.expj(-2 * :math.pi() * k * l / 256)) end)
    |> Cx.sum()
  end

  test "ring image: 1 MB, and words round-trip through the capture decoder" do
    img = Sounder.ring_image()
    assert byte_size(img) == 131_072 * 8
    words = for <<w::little-unsigned-64 <- binary_part(img, 0, 8 * 2048)>>, do: w
    {c1, c2} = Sounder.decode_capture(words)
    want = Sounder.period_samples()
    q = fn {a, b} -> {round(a), round(b)} end

    for {{t1, t2}, i} <- Enum.with_index(want) do
      {a, b} = q.(t1)
      {c, d} = q.(t2)
      assert elem(c1, i) == {a * 1.0, b * 1.0} or abs(a) >= 2047 or abs(b) >= 2047
      assert elem(c2, i) == {c * 1.0, d * 1.0} or abs(c) >= 2047 or abs(d) >= 2047
    end

    assert Enum.all?(words, &(&1 >>> 48 == 0))
  end

  test "recovers a 2x2 multipath channel through CFO, offset and noise" do
    {r1, r2} = channel(tx(18), 777, 16 * 2048, 2_500.0, 30, 1)
    dc = fn r, off -> r |> Tuple.to_list() |> Enum.map(&Cx.add(&1, off)) |> List.to_tuple() end
    cap = {dc.(r1, {900.0, -400.0}), dc.(r2, {-300.0, 700.0})}
    a = Sounder.analyse(cap)
    assert_in_delta a.cfo_hz, 2_500.0, 20.0
    assert length(a.periods) >= 14

    for p <- a.periods, k <- Sounder.tones() do
      h = Map.fetch!(p.h, k)
      r = Cx.div(Sounder.entry(h, 0, 0), h_true(0, 0, k))
      assert_in_delta :math.sqrt(Cx.abs2(r)), 1.0, 0.25

      for rx <- 0..1, tx <- 0..1 do
        e = Cx.sub(Sounder.entry(h, rx, tx), Cx.mul(r, h_true(rx, tx, k)))
        assert Cx.abs2(e) < 0.02, "k #{k} rx #{rx} tx #{tx} err #{Cx.abs2(e)}"
      end
    end

    s = Sounder.summary(a)
    [[p11, p12], [p21, p22]] = s.power_db
    assert abs(p11 - p22) < 3 and abs(p12 - p21) < 3
    assert Enum.all?(List.flatten(s.snr_db), &(&1 > 20))
  end
end
