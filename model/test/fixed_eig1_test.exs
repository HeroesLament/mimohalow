defmodule MimoHalow.Model.FixedEig1Test do
  use ExUnit.Case, async: true
  alias MimoHalow.Model.{Cx, Mat2}
  alias MimoHalow.Model.Fixed.{Mrc, VPrecode}
  alias MimoHalow.Model.Mimo.Channel

  # One OFDM symbol's worth of subcarriers, flat 2x2 Rayleigh per tone,
  # beamformed LTF (two repetitions) and QPSK data through the fixed
  # precoder; float channel + noise; integer "FFT outputs" into Mrc.
  @tones Enum.to_list(-26..-1) ++ Enum.to_list(1..26)
  @amp 6000

  defp run(snr_db, seed) do
    rng = Channel.rng(seed)
    {hs, rng} = Enum.map_reduce(@tones, rng, fn _, r -> Channel.rayleigh2(r) end)
    hs = Map.new(Enum.zip(@tones, hs))
    vs = Map.new(hs, fn {k, h} -> {_, _, v} = Mat2.svd(h); {k, Mat2.col(v, 0)} end)
    tab = VPrecode.table(vs)
    {signs, rng} = Enum.map_reduce(@tones, rng, fn k, r -> {b, r} = :rand.uniform_s(2, r); {{k, 2 * b - 3}, r} end)
    sign = Map.new(signs)
    {qs, rng} = Enum.map_reduce(@tones, rng, fn k, r -> {b, r} = :rand.uniform_s(4, r); {{k, b - 1}, r} end)
    qpsk = Map.new(qs, fn {k, b} -> {k, {if(rem(b, 2) == 0, do: 1, else: -1), if(b < 2, do: 1, else: -1)}} end)
    a = round(@amp / :math.sqrt(2))
    # noise per receive sample, relative to the per-chain signal power of a unit channel
    sigma2 = @amp * @amp * :math.pow(10, -snr_db / 10)

    rx = fn sym, rng ->
      Enum.map_reduce(@tones, rng, fn k, rng ->
        {a1, a2} = VPrecode.apply(tab, k, Map.fetch!(sym, k))
        {{h11, h12}, {h21, h22}} = hs[k]
        t1 = Cx.new(elem(a1, 0), elem(a1, 1))
        t2 = Cx.new(elem(a2, 0), elem(a2, 1))
        {n1, rng} = Channel.cn(rng, sigma2)
        {n2, rng} = Channel.cn(rng, sigma2)
        y1 = Cx.add(Cx.add(Cx.mul(h11, t1), Cx.mul(h12, t2)), n1)
        y2 = Cx.add(Cx.add(Cx.mul(h21, t1), Cx.mul(h22, t2)), n2)
        r = fn {x, y} -> {round(x), round(y)} end
        {{k, r.(y1), r.(y2)}, rng}
      end)
      |> then(fn {l, rng} -> {{Map.new(l, fn {k, y1, _} -> {k, y1} end), Map.new(l, fn {k, _, y2} -> {k, y2} end)}, rng} end)
    end

    ltf = Map.new(@tones, fn k -> {k, {sign[k] * @amp, 0}} end)
    data = Map.new(@tones, fn k -> {sx, sy} = qpsk[k]; {k, {sx * a, sy * a}} end)
    {{l1a, l1b}, rng} = rx.(ltf, rng)
    {{l2a, l2b}, rng} = rx.(ltf, rng)
    {{ya, yb}, _} = rx.(data, rng)
    est = Mrc.estimate([l1a, l1b], [l2a, l2b], @tones, sign)
    out = Mrc.combine(est, [ya, yb], @tones)
    %{hs: hs, vs: vs, qpsk: qpsk, out: out, a: a, est: est}
  end

  test "precoder table: Q1.14, v1 real non-negative, unit norm" do
    rng = Channel.rng(1)
    {h, _} = Channel.rayleigh2(rng)
    {_, _, v} = Mat2.svd(h)
    %{0 => {{v1r, v1i}, {v2r, v2i}}} = VPrecode.table(%{0 => Mat2.col(v, 0)})
    assert v1i == 0 and v1r >= 0
    assert_in_delta (v1r * v1r + v2r * v2r + v2i * v2i) / 16384 / 16384, 1.0, 1.0e-3
  end

  test "eig1 subcarrier loop: fixed MRC matches the float receiver and decides correctly" do
    for seed <- 1..5 do
      %{hs: hs, vs: vs, qpsk: qpsk, out: out, a: a} = run(35, seed)

      for k <- @tones do
        {{dr, di}, g} = out[k]
        # D / G = A_data x / (2 A_ltf): x = 2 A_ltf D / (A_data G)
        x = Cx.scale({dr * 1.0, di * 1.0}, 2 * @amp / (a * g))
        {sx, sy} = qpsk[k]
        assert {sign(elem(x, 0)), sign(elem(x, 1))} == {sx, sy}, "seed #{seed} tone #{k}"
        # float eig1: unit-power symbol on the strongest eigenmode, gain s1
        {_, {s1, _}, _} = Mat2.svd(hs[k])
        heff = Mat2.mulv(hs[k], vs[k])
        assert_in_delta Mat2.vnorm2(heff), s1 * s1, 1.0e-6
        assert_in_delta elem(x, 0), sx, 0.25
        assert_in_delta elem(x, 1), sy, 0.25
      end
    end
  end

  test "G tracks the eigenmode gain: G / (4 A^2 |Hv|^2 >> sh, >> 16) within quantisation" do
    %{hs: hs, vs: vs, out: out, est: %{sh: sh}} = run(60, 9)

    for k <- @tones do
      {_, g} = out[k]
      want = 4 * @amp * @amp * Mat2.vnorm2(Mat2.mulv(hs[k], vs[k])) / :math.pow(2, 2 * sh + 16)
      assert abs(g - want) <= 0.02 * want + 2, "tone #{k}: g #{g} want #{want}"
    end
  end

  defp sign(x) when x >= 0, do: 1
  defp sign(_), do: -1
end
