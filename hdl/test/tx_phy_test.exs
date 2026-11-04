defmodule MimoHalow.Hw.Tx.TxPhyTest do
  use ExUnit.Case
  import Bitwise
  alias MimoHalow.Model.S1g.{Air, Params, Ppdu}
  alias MimoHalow.Test.Cosim

  @mod_code %{bpsk: 0, qpsk: 1, qam16: 2, qam64: 3, qam256: 4}
  @rate_code %{{1, 2} => 0, {2, 3} => 1, {3, 4} => 2, {5, 6} => 3}
  @scale 6560

  defp case_for(mcs, len, seed) do
    :rand.seed(:exsss, {mcs, len, seed})
    psdu = :rand.bytes(len - 4) |> then(&(&1 <> <<:erlang.crc32(&1)::little-32>>))
    p = Ppdu.tx(psdu, bw: 2, mcs: mcs, scrambler: seed)

    sig =
      for {tones, n} <- Enum.with_index(p.sig), {kk, j} <- Enum.with_index(Params.sig_data(2)), reduce: 0 do
        acc ->
          {_, im} = Map.fetch!(tones, kk)
          if im > 0, do: acc ||| 1 <<< (48 * n + j), else: acc
      end

    # Model: Ppdu samples at the Ofdm scale, /16 to 12-bit units, Air.interp4.
    want =
      p.samples
      |> Enum.map(fn {re, im} -> {round(re * @scale) / 16, round(im * @scale) / 16} end)
      |> Air.interp4()
      |> Enum.map(fn {re, im} -> {round(re), round(im)} end)

    %{mcs: mcs, seed: seed, rate: @rate_code[p.rate.rate], mod: @mod_code[p.rate.mod], nsym: p.nsym,
      nbits: p.nsym * p.rate.ndbps, psdu: psdu, sig: sig, want: want}
  end

  defp hex32(v), do: v |> band(0xFFFF_FFFF) |> Integer.to_string(16)

  @tag :iverilog
  test "emitted Verilog: PSDU bytes -> 8 MS/s samples == Ppdu.tx |> Air.interp4, no underruns" do
    cases = [case_for(0, 24, 0x5D), case_for(3, 120, 0x11), case_for(7, 300, 0x7F), case_for(8, 600, 0x2A)]

    stim =
      Enum.flat_map(cases, fn c ->
        ["#{c.seed} #{c.rate} #{c.mod} #{c.nsym} #{c.nbits} #{byte_size(c.psdu)}",
         "#{hex32(c.sig >>> 64)} #{hex32(c.sig >>> 32)} #{hex32(c.sig)}"] ++
          for(<<b <- c.psdu>>, do: Cosim.hex(b, 8))
      end)

    out = Cosim.run([MimoHalow.Hw.Tx.TxPhy], "tb_tx_phy.v", stim, header: "#{length(cases)}")

    groups =
      Enum.chunk_while(out, [], fn
        "E " <> t, acc -> {:cont, {Enum.reverse(acc), t |> String.split() |> Enum.map(&String.to_integer/1)}, []}
        l, acc -> {:cont, [l |> String.split() |> Enum.map(&String.to_integer/1) |> List.to_tuple() | acc]}
      end, fn [] -> {:cont, []}; acc -> {:cont, acc, []} end)

    assert length(groups) == length(cases)

    for {c, {got, [cyc, under]}} <- Enum.zip(cases, groups) do
      assert length(got) == length(c.want), "MCS#{c.mcs}: #{length(got)} samples, want #{length(c.want)}"
      errs = Enum.zip_with(got, c.want, fn {gi, gq}, {wi, wq} -> max(abs(gi - wi), abs(gq - wq)) end)
      maxe = Enum.max(errs)
      rms = :math.sqrt(Enum.sum(Enum.map(errs, &(&1 * &1))) / length(errs))
      w = Enum.find_index(errs, &(&1 == maxe))
      if maxe > 3, do: flunk("MCS#{c.mcs}: max err #{maxe} at #{w} (got #{inspect(Enum.at(got, w))} want #{inspect(Enum.at(c.want, w))})")
      assert under == 0, "MCS#{c.mcs}: #{under} underruns"
      IO.puts("MCS#{c.mcs}: #{length(got)} samples, max err #{maxe}, rms #{Float.round(rms, 3)}, #{cyc} cycles")
    end
  end
end
