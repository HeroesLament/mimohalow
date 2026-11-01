defmodule MimoHalow.Model.S1gTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias MimoHalow.Model.Cx
  alias MimoHalow.Model.S1g.{Coding, Params, Ppdu}

  @dir Path.expand("fixtures/s1g_ref", __DIR__)

  defp load(name) do
    [h, "init " <> init, "x " <> x, "sig " <> sig, "n " <> n | rows] =
      @dir |> Path.join(name <> ".txt") |> File.read!() |> String.split("\n", trim: true)

    hdr = h |> String.split() |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, String.to_integer(v)} end)
    bits = fn s -> s |> String.graphemes() |> Enum.map(&String.to_integer/1) end
    n = String.to_integer(n)

    samples =
      rows
      |> Enum.take(n)
      |> Enum.map(fn r -> [a, b] = String.split(r); Cx.new(num(a), num(b)) end)

    # Reference prbsf(fliplr(init)): register cell x_k = fliplr(init)(k).
    seed = init |> bits.() |> Enum.reverse() |> Enum.with_index() |> Enum.reduce(0, fn {b, k}, a -> a ||| b <<< k end)
    %{hdr: hdr, seed: seed, x: bits.(x), sig: bits.(sig), samples: samples}
  end

  defp num(s), do: elem(Float.parse(s), 0)

  @short ~w(1m_mcs0_100 1m_mcs1_37 1m_mcs2_300 1m_mcs4_700 1m_mcs10_40 2s_mcs0_100 2s_mcs2_600 2s_mcs3_1500 2s_mcs4_300)

  defp psdu(v), do: Coding.bits_to_bytes(v.x ++ Coding.fcs(v.x))

  # Sample index of each OFDM symbol start (the windowed overlap samples).
  defp boundaries(bw, nsym) do
    n = Params.nfft(bw)
    gi = Params.gi(bw)
    blocks =
      List.duplicate(gi + n, if(bw == 1, do: 4, else: 2)) ++
        [2 * gi + 2 * n] ++
        if(bw == 1, do: [gi + n, gi + n], else: []) ++
        List.duplicate(gi + n, Params.sig_syms(bw) + nsym)

    {starts, _} = Enum.map_reduce(blocks, 0, fn l, at -> {at, at + l} end)
    MapSet.new(starts)
  end

  test "tone plans" do
    assert {length(Params.used(1)), length(Params.data(1))} == {26, 24}
    assert {length(Params.used(2)), length(Params.data(2)), length(Params.sig_data(2))} == {56, 52, 48}
    assert map_size(Params.ltf(1)) == 26 and map_size(Params.ltf(2)) == 56
    assert Enum.all?(Map.values(Params.ltf(2)), &(&1 in [-1, 1]))
    assert {:error, :invalid} = Params.rate(2, 9)
    assert {:ok, %{ndbps: 6, ncbps: 12}} = Params.rate(1, 10)
    assert {:ok, %{ndbps: 160}} = Params.rate(1, 9)
  end

  test "interleaver is a permutation and inverts" do
    for {bw, nb} <- [{1, 1}, {1, 2}, {1, 8}, {2, 1}, {2, 4}, {2, 8}, {:sig2, 1}] do
      geo = Params.interleaver(bw, nb)
      ncbps = if bw == :sig2, do: 48, else: length(Params.data(bw)) * nb
      p = Coding.perm(geo, nb, ncbps)
      assert Enum.sort(p) == Enum.to_list(0..(ncbps - 1))
      x = Enum.to_list(0..(ncbps - 1))
      assert x |> Coding.interleave(geo, nb) |> Coding.deinterleave(geo, nb) == x
    end
  end

  for name <- @short do
    test "reference #{name}: SIG bits, TX samples, RX decode" do
      v = load(unquote(name))
      bw = v.hdr["bw"]
      p = psdu(v)
      assert byte_size(p) == v.hdr["length_psdu"]

      t = Ppdu.tx(p, bw: bw, mcs: v.hdr["mcs"], scrambler: v.seed, aggregation: v.hdr["aggr"] == 1)
      assert t.nsym == v.hdr["nsym"]
      assert t.rate.ndbps == v.hdr["ndbps"]
      assert Ppdu.sig_bits(bw, t.fields) == v.sig

      # Time domain equal except the one-sample window overlaps at symbol starts.
      assert length(v.samples) == length(t.samples) + 1
      skip = boundaries(bw, t.nsym)

      bad =
        Enum.zip([t.samples, v.samples, 0..length(t.samples)])
        |> Enum.reject(fn {_, _, i} -> MapSet.member?(skip, i) end)
        |> Enum.filter(fn {a, b, _} -> Cx.abs2(Cx.sub(a, b)) > 1.0e-14 end)

      assert bad == [], "#{length(bad)} samples differ, first #{inspect(Enum.take(bad, 3))}"

      # The reference waveform decodes.
      assert {:ok, r} = Ppdu.rx(v.samples, bw)
      assert r.fields.mcs == v.hdr["mcs"]
      assert r.psdu == p
      assert r.fcs_ok
    end
  end

  defp awgn(xs, snr_db, seed) do
    :rand.seed(:exsss, {seed, 7, 11})
    s = :math.sqrt(:math.pow(10, -snr_db / 10) / 2)
    Enum.map(xs, fn {a, b} -> {a + s * :rand.normal(), b + s * :rand.normal()} end)
  end

  # Static multipath: 3 taps, delay spread inside the GI.
  defp multipath(xs) do
    taps = [{0, {0.9, 0.1}}, {2, {-0.3, 0.25}}, {5, {0.12, -0.08}}]
    t = List.to_tuple(xs)

    for i <- 0..(tuple_size(t) - 1) do
      taps |> Enum.map(fn {d, h} -> if i - d >= 0, do: Cx.mul(h, elem(t, i - d)), else: Cx.zero() end) |> Cx.sum()
    end
  end

  test "loopback every MCS at both widths through multipath + 30 dB AWGN" do
    for bw <- [1, 2], m <- 0..10, match?({:ok, _}, Params.rate(bw, m)) do
      body = :crypto.strong_rand_bytes(150 + 7 * m)
      p = body <> Coding.bits_to_bytes(Coding.fcs(Coding.bytes_to_bits(body)))
      t = Ppdu.tx(p, bw: bw, mcs: m, scrambler: 1 + rem(17 * m + bw, 127))
      y = t.samples |> multipath() |> awgn(30, 13 * m + bw)
      assert {:ok, r} = Ppdu.rx(y, bw), "bw #{bw} mcs #{m}"
      assert r.psdu == p and r.fcs_ok, "bw #{bw} mcs #{m}"
    end
  end

  test "corrupted SIG fails its CRC" do
    t = Ppdu.tx(<<1, 2, 3, 4, 5, 6>>, bw: 2, mcs: 1)
    bits = Ppdu.sig_bits(2, t.fields)
    assert {:ok, _} = Ppdu.parse_sig(2, bits)
    assert {:error, :crc} = Ppdu.parse_sig(2, List.update_at(bits, 20, &(1 - &1)))
  end

  test "MCS10 decodes where MCS0 fails (1 MHz, 2 dB)" do
    p = <<0::size(60 * 8)>> |> then(&(&1 <> Coding.bits_to_bytes(Coding.fcs(Coding.bytes_to_bits(&1)))))
    ok = fn m, snr, seed -> match?({:ok, %{fcs_ok: true}}, Ppdu.tx(p, bw: 1, mcs: m) |> Map.get(:samples) |> awgn(snr, seed) |> Ppdu.rx(1)) end
    # Below ~1 dB the SIG (same rep2 BPSK coding as MCS10) limits both.
    assert Enum.count(1..12, &ok.(10, 2.0, &1)) > Enum.count(1..12, &ok.(0, 2.0, &1)) + 2
  end
end
