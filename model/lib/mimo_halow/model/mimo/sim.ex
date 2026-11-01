defmodule MimoHalow.Model.Mimo.Sim do
  @moduledoc """
  Uncoded BER of the 2x2 schemes on i.i.d. Rayleigh block fading, compared at
  equal bits per channel use: one-stream schemes carry `bits` per symbol, the
  two-stream schemes `bits / 2` per stream. Total transmit power 1, SNR =
  1 / sigma2 per receive antenna.
  """
  alias MimoHalow.Model.{Cx, Mat2, Qam}
  alias MimoHalow.Model.Mimo.{Channel, Detect, Precode, Stbc}

  @schemes [:siso, :mrc_1x2, :alamouti, :eigen_1ss, :sm_mmse, :sm_ml, :svd_2ss]
  @r 1 / :math.sqrt(2)

  def schemes, do: @schemes

  def mods(2), do: {:qpsk, :bpsk}
  def mods(4), do: {:qam16, :qpsk}
  def mods(8), do: {:qam256, :qam16}

  def ber(scheme, snr_db, bits, trials, seed) do
    sigma2 = :math.pow(10, -snr_db / 10)
    {m1, m2} = mods(bits)

    {errs, nbits, _} =
      Enum.reduce(1..trials//1, {0, 0, Channel.rng(seed)}, fn _, {e, n, rng} ->
        {sent, got, rng} = trial(scheme, sigma2, m1, m2, rng)
        {e + errors(sent, got), n + length(sent), rng}
      end)

    errs / nbits
  end

  def trial(:siso, sigma2, m, _, rng) do
    {{{h, _}, _}, rng} = Channel.rayleigh2(rng)
    {b, rng} = Channel.bits(rng, Qam.nbpsc(m))
    {n, rng} = Channel.cn(rng, sigma2)
    y = Cx.add(Cx.mul(h, Qam.point(b, m)), n)
    {b, Qam.slice(Cx.div(y, h), m), rng}
  end

  def trial(:mrc_1x2, sigma2, m, _, rng) do
    {{{h1, _}, {h2, _}}, rng} = Channel.rayleigh2(rng)
    {b, rng} = Channel.bits(rng, Qam.nbpsc(m))
    {{n1, n2}, rng} = Channel.noise2(rng, sigma2)
    x = Qam.point(b, m)
    y1 = Cx.add(Cx.mul(h1, x), n1)
    y2 = Cx.add(Cx.mul(h2, x), n2)
    z = Cx.add(Cx.mul(Cx.conj(h1), y1), Cx.mul(Cx.conj(h2), y2))
    {b, Qam.slice(Cx.scale(z, 1 / (Cx.abs2(h1) + Cx.abs2(h2))), m), rng}
  end

  def trial(:alamouti, sigma2, m, _, rng) do
    {h, rng} = Channel.rayleigh2(rng)
    {b, rng} = Channel.bits(rng, 2 * Qam.nbpsc(m))
    [s1, s2] = Qam.map(b, m)
    {t1, t2} = Stbc.encode(s1, s2)
    {n1, rng} = Channel.noise2(rng, sigma2)
    {n2, rng} = Channel.noise2(rng, sigma2)
    y1 = Mat2.vadd(Mat2.mulv(h, t1), n1)
    y2 = Mat2.vadd(Mat2.mulv(h, t2), n2)
    {e1, e2, _} = Stbc.decode(h, y1, y2, sigma2)
    {b, Qam.slice(e1, m) ++ Qam.slice(e2, m), rng}
  end

  def trial(:eigen_1ss, sigma2, m, _, rng) do
    {h, rng} = Channel.rayleigh2(rng)
    {b, rng} = Channel.bits(rng, Qam.nbpsc(m))
    {n, rng} = Channel.noise2(rng, sigma2)
    y = Mat2.vadd(Mat2.mulv(h, Precode.eigen_1ss_tx(h, Qam.point(b, m))), n)
    {e, _} = Precode.eigen_1ss_rx(h, y, sigma2)
    {b, Qam.slice(e, m), rng}
  end

  def trial(scheme, sigma2, _, m, rng) when scheme in [:sm_mmse, :sm_ml] do
    {h, rng} = Channel.rayleigh2(rng)
    {b, rng} = Channel.bits(rng, 2 * Qam.nbpsc(m))
    [p1, p2] = Qam.map(b, m)
    {n, rng} = Channel.noise2(rng, sigma2)
    heff = scale(h, @r)
    y = Mat2.vadd(Mat2.mulv(heff, {p1, p2}), n)

    got =
      case scheme do
        :sm_mmse -> Detect.mmse_bits(heff, y, sigma2, m)
        :sm_ml -> Detect.ml_bits(heff, y, m)
      end

    {b, got, rng}
  end

  def trial(:svd_2ss, sigma2, _, m, rng) do
    {h, rng} = Channel.rayleigh2(rng)
    {b, rng} = Channel.bits(rng, 2 * Qam.nbpsc(m))
    [p1, p2] = Qam.map(b, m)
    {n, rng} = Channel.noise2(rng, sigma2)
    y = Mat2.vadd(Mat2.mulv(h, Precode.svd_2ss_tx(h, {p1, p2})), n)
    {{e1, e2}, _} = Precode.svd_2ss_rx(h, y, sigma2)
    {b, Qam.slice(e1, m) ++ Qam.slice(e2, m), rng}
  end

  defp scale({{a, b}, {c, d}}, k), do: {{Cx.scale(a, k), Cx.scale(b, k)}, {Cx.scale(c, k), Cx.scale(d, k)}}

  defp errors(a, b), do: Enum.zip_with(a, b, fn x, y -> if x == y, do: 0, else: 1 end) |> Enum.sum()
end
