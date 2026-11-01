defmodule MimoHalow.Model.Fixed.DataDecTest do
  use ExUnit.Case, async: true
  alias MimoHalow.Model.Fixed.{Cpe, DataDec}
  alias MimoHalow.Model.S1g.{Coding, Params, Ppdu}

  @data Params.data(2)

  defp psdu(n, seed) do
    :rand.seed(:exsss, {seed, 2, 9})
    body = for _ <- 1..n, into: <<>>, do: <<:rand.uniform(256) - 1>>
    body <> Coding.bits_to_bytes(Coding.fcs(Coding.bytes_to_bits(body)))
  end

  # Cpe-like integers: D' = (K/2) G x + noise, G per tone (a channel's |h|^2 profile).
  defp cpe_points(t, noise, seed) do
    :rand.seed(:exsss, {seed, 5, 1})
    gs = Map.new(@data, fn k -> {k, 30_000 + :rand.uniform(600_000)} end)
    h = Cpe.gain() / 2

    to_pts = fn tones ->
      for k <- @data do
        {xr, xi} = Map.get(tones, k, {0.0, 0.0})
        g = gs[k]
        sig = noise * :math.sqrt(g)
        {round(h * g * xr + sig * :rand.normal()), round(h * g * xi + sig * :rand.normal()), g}
      end
    end

    {Enum.map(to_pts.(hd(t.sig)), &elem(&1, 2)), Enum.map(t.data, to_pts)}
  end

  test "thresholds: 16-QAM matches OcuSync's demapper constant" do
    assert DataDec.consts(:qam16) == [34_131] or DataDec.consts(:qam16) == [34_128] or
             abs(hd(DataDec.consts(:qam16)) - 34_128) < 8
    assert length(DataDec.consts(:qam256)) == 3
  end

  test "noiseless and noisy decode, every 2 MHz MCS, short and long (multi-window) PPDUs" do
    for m <- 0..8, {n, noise, seed} <- [{60, 0.0, 1}, {420, 3.0, 2}] do
      p = psdu(n, 10 * m + seed)
      t = Ppdu.tx(p, bw: 2, mcs: m, scrambler: 1 + rem(13 * m + seed, 127))
      # At high MCS give the noisy case more SNR.
      nz = noise / :math.pow(2, div(m, 2))
      {g0, syms} = cpe_points(t, nz, m + seed)
      r = DataDec.decode(g0, syms, m, byte_size(p), t.fields.aggregation)
      assert r.psdu == p, "mcs #{m} n #{n} noise #{nz} (q #{r.q})"
      assert Ppdu.fcs_ok?(r.psdu)
    end
  end

  test "aggregated PPDU: length from Nsym" do
    p = psdu(700, 3)
    t = Ppdu.tx(p, bw: 2, mcs: 3, scrambler: 33)
    assert t.fields.aggregation
    {g0, syms} = cpe_points(t, 1.0, 9)
    r = DataDec.decode(g0, syms, 3, nil, true)
    assert binary_part(r.psdu, 0, byte_size(p)) == p
  end

  test "windowed traceback agrees with full-packet Viterbi at moderate noise" do
    :rand.seed(:exsss, {7, 7, 7})
    bits = (for _ <- 1..1500, do: :rand.uniform(2) - 1) ++ List.duplicate(0, 6)
    coded = MimoHalow.Model.Bcc.encode(bits)
    softs = Enum.map(coded, fn c -> (2 * c - 1) * 8 + round(5 * :rand.normal()) |> max(-31) |> min(31) end)
    got = DataDec.viterbi(softs)
    ref = MimoHalow.Model.Bcc.viterbi(Enum.map(softs, &(-1.0 * &1)), terminated: true)
    diff = Enum.zip(got, ref) |> Enum.count(fn {a, b} -> a != b end)
    assert diff <= 3
    errs = Enum.zip(got, bits) |> Enum.count(fn {a, b} -> a != b end)
    assert errs < 30
  end
end
