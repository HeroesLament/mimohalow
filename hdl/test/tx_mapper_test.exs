defmodule MimoHalow.Hw.Tx.MapperTest do
  use ExUnit.Case
  alias MimoHalow.Model.{Qam}
  alias MimoHalow.Model.S1g.{Coding, Params}
  alias MimoHalow.Test.Cosim

  @mod_code %{bpsk: 0, qpsk: 1, qam16: 2, qam64: 3, qam256: 4}

  # Model: per symbol, interleave then map; levels = point / k_mod.
  defp model(bits, r) do
    bits
    |> Enum.chunk_every(r.ncbps)
    |> Enum.flat_map(fn c ->
      x = Coding.interleave(c, Params.interleaver(2, r.nbpsc), r.nbpsc)
      pts = Qam.map(x, r.mod)
      k = Qam.k_mod(r.mod)

      for {p, j} <- Enum.with_index(pts) do
        bin = Params.bin(Enum.at(Params.data(2), j), 2)
        {re, im} = p
        {bin, round(re / k), round(im / k), if(j == 51, do: 1, else: 0)}
      end
    end)
  end

  @tag :iverilog
  test "emitted Verilog == Coding.interleave + Qam.map levels, all five modulations, stalls" do
    cases =
      for {mcs, nsym} <- [{0, 3}, {1, 2}, {3, 2}, {5, 2}, {8, 3}] do
        :rand.seed(:exsss, {mcs, nsym, 3})
        {:ok, r} = Params.rate(2, mcs)
        bits = for _ <- 1..(nsym * r.ncbps), do: :rand.uniform(2) - 1
        {mcs, r, bits, model(bits, r)}
      end

    stim =
      Enum.flat_map(cases, fn {_, r, bits, _} ->
        ["#{@mod_code[r.mod]} #{length(bits)}" | Enum.map(bits, &Integer.to_string/1)]
      end)

    out = Cosim.run([MimoHalow.Hw.Tx.Mapper], "tb_tx_mapper.v", stim, header: "#{length(cases)}")

    groups =
      Enum.chunk_while(out, [], fn
        "E " <> cyc, acc -> {:cont, {Enum.reverse(acc), String.to_integer(cyc)}, []}
        l, acc -> {:cont, [l |> String.split() |> Enum.map(&String.to_integer/1) |> List.to_tuple() | acc]}
      end, fn [] -> {:cont, []}; acc -> {:cont, acc, []} end)

    assert length(groups) == length(cases)

    for {{mcs, r, bits, want}, {got, cyc}} <- Enum.zip(cases, groups) do
      assert length(got) == length(want), "MCS#{mcs}: #{length(got)} points, want #{length(want)}"
      first = Enum.zip(got, want) |> Enum.find_index(fn {g, w} -> g != w end)
      if first, do: flunk("MCS#{mcs}: point #{first} got #{inspect(Enum.at(got, first))} want #{inspect(Enum.at(want, first))}")
      # Budget: a 2 MHz symbol is 1280 data_clk cycles; stalls here roughly halve throughput.
      nsym = div(length(bits), r.ncbps)
      assert cyc < 2 * 1280 * nsym + 2000, "MCS#{mcs}: #{cyc} cycles for #{nsym} symbols"
    end
  end
end
