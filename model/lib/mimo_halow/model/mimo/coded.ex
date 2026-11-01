defmodule MimoHalow.Model.Mimo.Coded do
  @moduledoc """
  Coded packet error rate of the 2x2 schemes: one LDPC n = 648 R = 1/2
  codeword per packet, padded to whole channel uses, pseudo-random bit
  interleaving, slots spread over the 52 data subcarriers. Equal bits per
  channel use as `Sim`. SNR = 1 / sigma2 per receive antenna, total transmit
  power 1.

  Channel options (`chopts`):
    * none: a fresh `OfdmChannel` Rayleigh draw per packet (`:ntaps`, `:rms`);
    * `hs: [2x2]`: a fixed channel per data subcarrier (a measured trace);
    * `hs_tx: [2x2]`: the channel the transmitter computes its precoder from
      (stale explicit feedback); defaults to the true channel.

  The receiver always knows the channel it actually sees (from the LTFs):
  the precoded schemes are received by MRC (one stream) or MMSE (two
  streams) on the effective channel `H V`, which is exact when `hs_tx`
  equals `hs`.
  """
  alias MimoHalow.Model.{Cx, Demap, Ldpc, Mat2, Qam}
  alias MimoHalow.Model.Mimo.{Channel, Detect, OfdmChannel, Sim, Stbc}

  @r 1 / :math.sqrt(2)
  @clamp 50.0

  def schemes, do: Sim.schemes()

  @doc "`{packet_errors, packets, mean_iters}`."
  def per(scheme, snr_db, bits, packets, seed, chopts \\ []) do
    sigma2 = :math.pow(10, -snr_db / 10)
    code = Ldpc.code()
    sc = OfdmChannel.data_subcarriers()

    {errs, iters, _} =
      Enum.reduce(1..packets//1, {0, 0, Channel.rng(seed)}, fn _, {e, it, rng} ->
        {ok, n_it, rng} = packet(scheme, sigma2, bits, code, sc, chopts, rng)
        {e + if(ok, do: 0, else: 1), it + n_it, rng}
      end)

    {errs, packets, iters / packets}
  end

  def packet(scheme, sigma2, bits, code, sc, chopts, rng) do
    {info, rng} = Channel.bits(rng, code.k)
    cw = Ldpc.encode(info, code)
    slots = slots(code.n, bits)
    {pad, rng} = Channel.bits(rng, slots * bits - code.n)
    perm = perm(slots * bits)
    tx_bits = permute(cw ++ pad, perm)

    {hs, rng} =
      case Keyword.fetch(chopts, :hs) do
        {:ok, hs} -> {hs, rng}
        :error -> OfdmChannel.draw(rng, sc, chopts)
      end

    hs_tx = Keyword.get(chopts, :hs_tx, hs)
    {llrs, rng} = run(scheme, tx_bits, {List.to_tuple(hs), List.to_tuple(hs_tx)}, sigma2, bits, rng)
    llrs = llrs |> unpermute(perm) |> Enum.take(code.n) |> Enum.map(&clamp/1)
    %{info: got, ok: ok, iters: n_it} = Ldpc.decode(llrs, [], code)
    {ok and got == info, n_it, rng}
  end

  defp slots(n, bits) do
    s = div(n + bits - 1, bits)
    s + rem(s, 2)
  end

  defp h_at(hs, i), do: elem(hs, rem(i, tuple_size(hs)))

  defp run(scheme, tx_bits, {hs, hts}, sigma2, bits, rng) when scheme in [:siso, :mrc_1x2, :eigen_1ss] do
    {m, _} = Sim.mods(bits)

    tx_bits
    |> Enum.chunk_every(bits)
    |> Enum.with_index()
    |> Enum.flat_map_reduce(rng, fn {b, i}, rng ->
      x = Qam.point(b, m)
      {n, rng} = Channel.noise2(rng, sigma2)
      {e, nv} = one_ss(scheme, h_at(hs, i), h_at(hts, i), x, n, sigma2)
      {Demap.llrs(e, nv, m), rng}
    end)
  end

  defp run(:alamouti, tx_bits, {hs, _}, sigma2, bits, rng) do
    {m, _} = Sim.mods(bits)

    tx_bits
    |> Enum.chunk_every(2 * bits)
    |> Enum.with_index()
    |> Enum.flat_map_reduce(rng, fn {b, j}, rng ->
      h = h_at(hs, j)
      [s1, s2] = Qam.map(b, m)
      {t1, t2} = Stbc.encode(s1, s2)
      {n1, rng} = Channel.noise2(rng, sigma2)
      {n2, rng} = Channel.noise2(rng, sigma2)
      y1 = Mat2.vadd(Mat2.mulv(h, t1), n1)
      y2 = Mat2.vadd(Mat2.mulv(h, t2), n2)
      {e1, e2, nv} = Stbc.decode(h, y1, y2, sigma2)
      {Demap.llrs(e1, nv, m) ++ Demap.llrs(e2, nv, m), rng}
    end)
  end

  defp run(scheme, tx_bits, {hs, hts}, sigma2, bits, rng) when scheme in [:sm_mmse, :sm_ml, :svd_2ss] do
    {_, m} = Sim.mods(bits)

    tx_bits
    |> Enum.chunk_every(bits)
    |> Enum.with_index()
    |> Enum.flat_map_reduce(rng, fn {b, i}, rng ->
      [p1, p2] = Qam.map(b, m)
      {n, rng} = Channel.noise2(rng, sigma2)
      {two_ss(scheme, h_at(hs, i), h_at(hts, i), {p1, p2}, n, sigma2, m), rng}
    end)
  end

  defp one_ss(:siso, {{h, _}, _}, _ht, x, {n, _}, sigma2) do
    y = Cx.add(Cx.mul(h, x), n)
    {Cx.div(y, h), sigma2 / Cx.abs2(h)}
  end

  defp one_ss(:mrc_1x2, {{h1, _}, {h2, _}}, _ht, x, {n1, n2}, sigma2) do
    y1 = Cx.add(Cx.mul(h1, x), n1)
    y2 = Cx.add(Cx.mul(h2, x), n2)
    g = Cx.abs2(h1) + Cx.abs2(h2)
    z = Cx.add(Cx.mul(Cx.conj(h1), y1), Cx.mul(Cx.conj(h2), y2))
    {Cx.scale(z, 1 / g), sigma2 / g}
  end

  # Precoder from the transmitter's channel; MRC on the effective channel.
  defp one_ss(:eigen_1ss, h, ht, x, n, sigma2) do
    {_, _, v} = Mat2.svd(ht)
    v1 = Mat2.col(v, 0)
    heff = Mat2.mulv(h, v1)
    {a, b} = heff
    y = Mat2.vadd({Cx.mul(a, x), Cx.mul(b, x)}, n)
    g = Mat2.vnorm2(heff)
    {Cx.scale(Mat2.vdot(heff, y), 1 / g), sigma2 / g}
  end

  # Precoder from the transmitter's channel; MMSE on the effective channel.
  defp two_ss(:svd_2ss, h, ht, p, n, sigma2, m) do
    {_, _, v} = Mat2.svd(ht)
    heff = scale(Mat2.mul(h, v), @r)
    y = Mat2.vadd(Mat2.mulv(heff, p), n)
    {{e1, e2}, {v1, v2}} = Detect.mmse(heff, y, sigma2)
    Demap.llrs(e1, v1, m) ++ Demap.llrs(e2, v2, m)
  end

  defp two_ss(scheme, h, _ht, p, n, sigma2, m) do
    heff = scale(h, @r)
    y = Mat2.vadd(Mat2.mulv(heff, p), n)

    case scheme do
      :sm_ml ->
        Detect.ml_llrs(heff, y, sigma2, m)

      :sm_mmse ->
        {{e1, e2}, {v1, v2}} = Detect.mmse(heff, y, sigma2)
        Demap.llrs(e1, v1, m) ++ Demap.llrs(e2, v2, m)
    end
  end

  defp scale({{a, b}, {c, d}}, k), do: {{Cx.scale(a, k), Cx.scale(b, k)}, {Cx.scale(c, k), Cx.scale(d, k)}}

  defp clamp(x), do: x |> max(-@clamp) |> min(@clamp)

  # Fixed pseudo-random interleaver over `n` positions.
  defp perm(n) do
    key = {__MODULE__, :perm, n}

    case :persistent_term.get(key, nil) do
      nil ->
        {p, _} =
          Enum.map_reduce(0..(n - 1), Channel.rng(0xC0DE + n), fn i, r ->
            {u, r} = :rand.uniform_s(r)
            {{u, i}, r}
          end)

        p = p |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> List.to_tuple()
        :persistent_term.put(key, p)
        p

      p ->
        p
    end
  end

  # Output position j carries input bit perm[j].
  defp permute(bits, p) do
    t = List.to_tuple(bits)
    for j <- 0..(tuple_size(p) - 1), do: elem(t, elem(p, j))
  end

  defp unpermute(vals, p) do
    vals
    |> Enum.with_index()
    |> Enum.map(fn {v, j} -> {elem(p, j), v} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end
end
