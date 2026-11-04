defmodule MimoHalow.Hw.Tx.OfdmTest do
  use ExUnit.Case
  import Bitwise
  alias MimoHalow.Model.Qam
  alias MimoHalow.Model.S1g.{Params, Ppdu}
  alias MimoHalow.Test.Cosim

  @mod_code %{bpsk: 0, qpsk: 1, qam16: 2, qam64: 3, qam256: 4}
  @scale 6560

  # Stimulus from the model's own tone maps: data levels in mapper order,
  # the 96 SIG bits from the sign of the SIG tones' Q.
  defp case_for(mcs, len) do
    :rand.seed(:exsss, {mcs, len, 11})
    psdu = :rand.bytes(len - 4) |> then(&(&1 <> <<:erlang.crc32(&1)::little-32>>))
    p = Ppdu.tx(psdu, bw: 2, mcs: mcs)
    k = Qam.k_mod(p.rate.mod)

    pts =
      for tones <- p.data, {kk, j} <- Enum.with_index(Params.data(2)) do
        {re, im} = Map.fetch!(tones, kk)
        {Params.bin(kk, 2), round(re / k), round(im / k), if(j == 51, do: 1, else: 0)}
      end

    sig =
      for {tones, n} <- Enum.with_index(p.sig), {kk, j} <- Enum.with_index(Params.sig_data(2)), reduce: 0 do
        acc ->
          {_, im} = Map.fetch!(tones, kk)
          if im > 0, do: acc ||| 1 <<< (48 * n + j), else: acc
      end

    want = Enum.map(p.samples, fn {re, im} -> {round(re * @scale), round(im * @scale)} end)
    %{mcs: mcs, mod: @mod_code[p.rate.mod], nsym: p.nsym, sig: sig, pts: pts, want: want}
  end

  defp hex32(v), do: v |> band(0xFFFF_FFFF) |> Integer.to_string(16)

  @tag :iverilog
  test "emitted Verilog == Ppdu.tx samples (preamble, SIG, data; 3 MCS; stalls)" do
    cases = [case_for(0, 40), case_for(4, 200), case_for(8, 300)]

    stim =
      Enum.flat_map(cases, fn c ->
        ["#{c.mod} #{c.nsym}", "#{hex32(c.sig >>> 64)} #{hex32(c.sig >>> 32)} #{hex32(c.sig)}"] ++
          Enum.map(c.pts, fn {b, i, q, l} -> "#{b} #{i} #{q} #{l}" end)
      end)

    out = Cosim.run([MimoHalow.Hw.Tx.Ofdm], "tb_tx_ofdm.v", stim, header: "#{length(cases)}")

    groups =
      Enum.chunk_while(out, [], fn
        "E " <> cyc, acc -> {:cont, {Enum.reverse(acc), String.to_integer(cyc)}, []}
        l, acc -> {:cont, [l |> String.split() |> Enum.map(&String.to_integer/1) |> List.to_tuple() | acc]}
      end, fn [] -> {:cont, []}; acc -> {:cont, acc, []} end)

    assert length(groups) == length(cases)

    for {c, {got, cyc}} <- Enum.zip(cases, groups) do
      assert length(got) == length(c.want), "MCS#{c.mcs}: #{length(got)} samples, want #{length(c.want)}"

      errs = Enum.zip_with(got, c.want, fn {gi, gq}, {wi, wq} -> max(abs(gi - wi), abs(gq - wq)) end)
      maxe = Enum.max(errs)
      rms = :math.sqrt(Enum.sum(Enum.map(errs, &(&1 * &1))) / length(errs))
      worst = Enum.find_index(errs, &(&1 == maxe))

      # 4 fraction bits: 16 = one 12-bit LSB. FFT rounding + the 3508/65536 scale.
      if maxe > 16,
        do: flunk("MCS#{c.mcs}: max err #{maxe} at #{worst} (got #{inspect(Enum.at(got, worst))} want #{inspect(Enum.at(c.want, worst))}), rms #{rms}")

      assert rms < 4.0, "MCS#{c.mcs}: rms err #{rms}"
      IO.puts("MCS#{c.mcs}: #{length(got)} samples, max err #{maxe}, rms #{Float.round(rms, 3)}, #{cyc} cycles")
    end
  end
end
