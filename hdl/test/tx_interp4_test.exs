defmodule MimoHalow.Hw.Tx.Interp4Test do
  use ExUnit.Case
  alias MimoHalow.Model.S1g.{Air, Ppdu}
  alias MimoHalow.Test.Cosim

  @scale 6560

  @tag :iverilog
  test "emitted Verilog == Air.interp4 (12-bit, 4n + 130 outputs, no underrun at the 8 MS/s pull)" do
    :rand.seed(:exsss, {4, 4, 4})
    psdu = :rand.bytes(96) |> then(&(&1 <> <<:erlang.crc32(&1)::little-32>>))
    p = Ppdu.tx(psdu, bw: 2, mcs: 4)
    x = Enum.map(p.samples, fn {re, im} -> {round(re * @scale), round(im * @scale)} end)
    stim = Enum.map(x, fn {i, q} -> "#{i} #{q}" end)

    out = Cosim.run([MimoHalow.Hw.Tx.Interp4], "tb_tx_interp4.v", stim)
    {body, ["E " <> tail]} = Enum.split(out, -1)
    [cyc, under] = tail |> String.split() |> Enum.map(&String.to_integer/1)
    got = Enum.map(body, fn l -> l |> String.split() |> Enum.map(&String.to_integer/1) |> List.to_tuple() end)

    # Model at the same scale: integer input (/ 16 for 12 bits), float filters.
    xf = Enum.map(x, fn {i, q} -> {i / 16, q / 16} end)
    want = xf |> Air.interp4() |> Enum.map(fn {re, im} -> {round(re), round(im)} end)

    assert length(got) == length(want), "#{length(got)} outputs, want #{length(want)}"
    assert length(got) == 4 * length(x) + 130

    errs = Enum.zip_with(got, want, fn {gi, gq}, {wi, wq} -> max(abs(gi - wi), abs(gq - wq)) end)
    maxe = Enum.max(errs)
    if maxe > 2, do: flunk("max err #{maxe} at #{Enum.find_index(errs, &(&1 == maxe))}")
    assert under == 0, "#{under} underruns at the 8 MS/s pull"
    IO.puts("interp4: #{length(got)} outputs, max err #{maxe} LSB, #{cyc} cycles, underruns #{under}")
  end
end
