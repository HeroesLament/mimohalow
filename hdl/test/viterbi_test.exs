defmodule MimoHalow.Hw.Rx.ViterbiTest do
  use ExUnit.Case
  alias MimoHalow.Model.Bcc
  alias MimoHalow.Model.Fixed.DataDec
  alias MimoHalow.Test.Cosim

  # Soft pairs of a terminated BCC packet: +-8 + noise, clamp +-31, some erasures.
  defp packet(nbits, noise, erase, seed) do
    :rand.seed(:exsss, {seed, 3, 3})
    bits = (for _ <- 1..nbits, do: :rand.uniform(2) - 1) ++ List.duplicate(0, 6)

    bits
    |> Bcc.encode()
    |> Enum.map(fn c ->
      if :rand.uniform() < erase, do: 0, else: ((2 * c - 1) * 8 + round(noise * :rand.normal())) |> max(-31) |> min(31)
    end)
  end

  @tag :iverilog
  @tag timeout: 900_000
  test "emitted Verilog == Fixed.DataDec.viterbi: window edges, erasures, bursts and gaps" do
    {b, d} = DataDec.depth()
    sizes = [{40, 2.0, 0.0}, {d + b - 6, 4.0, 0.1}, {d + b - 5, 4.0, 0.0}, {d + b + 1 - 6, 6.0, 0.2}, {1100, 6.0, 0.15}, {700, 3.0, 0.33}]
    pkts = sizes |> Enum.with_index() |> Enum.map(fn {{n, nz, er}, i} -> packet(n, nz, er, i + 1) end)
    :rand.seed(:exsss, {9, 9, 9})

    stim =
      Enum.flat_map(pkts, fn softs ->
        pairs = Enum.chunk_every(softs, 2)
        last = length(pairs) - 1

        pairs
        |> Enum.with_index()
        |> Enum.map(fn {[a, bb], i} ->
          # As the demapper delivers them: bursts of up to 312 back-to-back
          # pairs (2 MHz MCS8, one symbol) per 1280 cycles, occasional gaps,
          # a pause between PPDUs.
          gap = cond do
            i == 0 -> 300
            rem(i, 312) == 0 -> 1000
            :rand.uniform() < 0.1 -> :rand.uniform(6)
            true -> 0
          end

          "#{gap} #{if i == 0, do: 1, else: 0} #{if i == last, do: 1, else: 0} #{Cosim.hex(a, 6)} #{Cosim.hex(bb, 6)}"
        end)
      end)

    lines = Cosim.run([MimoHalow.Hw.Rx.Viterbi], "tb_viterbi.v", stim)
    {outs, ["O " <> ovf]} = Enum.split(lines, -1)
    assert ovf == "0"
    got = Enum.map(outs, fn l -> l |> String.split() |> Enum.map(&String.to_integer/1) end)

    want =
      Enum.flat_map(pkts, fn softs ->
        bits = DataDec.viterbi(softs)
        n = length(bits)
        bits |> Enum.with_index() |> Enum.map(fn {x, i} -> [x, if(i == n - 1, do: 1, else: 0)] end)
      end)

    assert length(got) == length(want)
    assert got == want
  end
end
