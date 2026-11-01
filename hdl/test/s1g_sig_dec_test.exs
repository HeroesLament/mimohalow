defmodule MimoHalow.Hw.Rx.S1gSigDecTest do
  use ExUnit.Case
  alias MimoHalow.Model.S1g.{Coding, Params, Ppdu}
  alias MimoHalow.Test.Cosim

  @data Params.data(2)

  # Cpe-like stream of one PPDU: SIG symbols j = 0, 1 (all 52 data indices,
  # Im carries QBPSK), then `extra` data symbols of junk; then idle slots.
  defp stream(sig_tones, extra, amp, noise, seed) do
    :rand.seed(:exsss, {seed, 6, 2})
    nz = fn -> round(noise * :rand.normal()) end

    sig =
      for {tones, j} <- Enum.with_index(sig_tones), {k, d} <- Enum.with_index(@data) do
        {_re, im} = Map.get(tones, k, {0.0, 0.0})
        "#{j} #{d} #{Cosim.hex(round(amp * im) + nz.(), 27)}"
      end

    junk = for j <- 2..(1 + extra), d <- 0..51, do: "#{j} #{d} #{Cosim.hex(nz.() * 50, 27)}"
    sig ++ junk ++ List.duplicate("2047 0 0", 500)
  end

  defp sig_value(bits), do: bits |> Enum.take(48) |> Coding.value()

  @tag :iverilog
  test "S1G SIG decoded: fields, nsym_total (bytes and aggregated), CRC / LDPC / MCS discards" do
    mk = fn len, opts -> Ppdu.tx(:binary.copy(<<0x5A>>, len), [bw: 2] ++ opts) end

    good = [
      {mk.(100, mcs: 0), 6.0e5, 2.0e4},
      {mk.(300, mcs: 4, smoothing: 0, id: 0x155), 3.0e5, 3.0e4},
      {mk.(1500, mcs: 7, aggregation: true), 4.0e6, 4.0e5},
      {mk.(37, mcs: 8), 1.0e5, 1.0e4}
    ]

    # Valid code words with bad contents: CRC wrong; coding = LDPC; MCS 9.
    t = mk.(100, mcs: 1)
    b = Ppdu.sig_bits(2, t.fields)
    bad_crc = List.update_at(b, 38, &(1 - &1))
    with_crc = fn bits -> h = Enum.take(bits, 38); h ++ Coding.crc4(h) ++ List.duplicate(0, 6) end
    ldpc = b |> List.replace_at(17, 1) |> with_crc.()
    mcs9 = b |> Enum.take(19) |> Kernel.++(Coding.bits(9, 4)) |> Kernel.++(Enum.drop(b, 23)) |> with_crc.()
    bads = for bits <- [bad_crc, ldpc, mcs9], do: Ppdu.sig_tones(2, bits)

    stim =
      (good |> Enum.with_index() |> Enum.flat_map(fn {{t, a, nz}, i} -> stream(t.sig, 3, a, nz, i) end)) ++
        (bads |> Enum.with_index() |> Enum.flat_map(fn {tones, i} -> stream(tones, 2, 5.0e5, 1.0e4, 10 + i) end))

    got =
      Cosim.run([MimoHalow.Hw.Rx.S1gSigDec], "tb_s1g_sig_dec.v", stim)
      |> Enum.map(fn l ->
        [ok, disc, nt, bits, nd] = String.split(l)
        {String.to_integer(ok), String.to_integer(disc), String.to_integer(nt), String.to_integer(bits, 16), String.to_integer(nd)}
      end)

    assert length(got) == length(good) + length(bads)
    {gg, gb} = Enum.split(got, length(good))

    for {{ok, disc, nt, bits, nd}, {t, _, _}} <- Enum.zip(gg, good) do
      assert bits == sig_value(Ppdu.sig_bits(2, t.fields))
      assert {ok, disc} == {1, 0}
      assert nd == t.nsym, "ndata #{nd} vs #{t.nsym} (mcs #{t.fields.mcs})"
      assert nt == 4 + t.nsym
    end

    assert [{0, 1, 4, _, _}, {1, 1, 4, _, _}, {1, 1, 4, _, _}] = gb
  end
end
