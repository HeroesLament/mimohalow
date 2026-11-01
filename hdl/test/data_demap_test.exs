defmodule MimoHalow.Hw.Rx.DataDemapTest do
  use ExUnit.Case
  alias MimoHalow.Model.Fixed.{Cpe, DataDec}
  alias MimoHalow.Model.S1g.{Coding, Params, Ppdu}
  alias MimoHalow.Test.Cosim

  @data Params.data(2)

  defp psdu(n, seed) do
    :rand.seed(:exsss, {seed, 4, 4})
    body = for _ <- 1..n, into: <<>>, do: <<:rand.uniform(256) - 1>>
    body <> Coding.bits_to_bytes(Coding.fcs(Coding.bytes_to_bits(body)))
  end

  # Cpe-like symbols (SIG j = 0, 1 then DATA), [{x, y, g}] in data-index order.
  defp points(t, noise, seed) do
    :rand.seed(:exsss, {seed, 5, 1})
    gs = Map.new(@data, fn k -> {k, 30_000 + :rand.uniform(900_000)} end)
    h = Cpe.gain() / 2

    for tones <- t.sig ++ t.data do
      for k <- @data do
        {xr, xi} = Map.get(tones, k, {0.0, 0.0})
        g = gs[k]
        sg = noise * :math.sqrt(g)
        {round(h * g * xr + sg * :rand.normal()), round(h * g * xi + sg * :rand.normal()), g}
      end
    end
  end

  defp stim(syms, mcs, ndata) do
    syms
    |> Enum.with_index()
    |> Enum.flat_map(fn {pts, j} ->
      lines = pts |> Enum.with_index() |> Enum.map(fn {{x, y, g}, d} -> "0 #{j} #{d} #{Cosim.hex(x, 27)} #{Cosim.hex(y, 27)} #{g}" end)
      sig = if j == 1, do: ["2 600", "1 #{mcs} #{ndata} 0"], else: []
      lines ++ sig ++ ["2 1200"]
    end)
  end

  @tag :iverilog
  @tag timeout: 900_000
  test "emitted Verilog == Fixed.DataDec.pairs: MCS 0-8, odd/even symbol counts back to back" do
    cases = for m <- 0..8, do: {m, 40 + 23 * m, 2.0, m + 1}
    cases = cases ++ [{3, 7, 1.0, 20}, {3, 61, 1.0, 21}]

    runs =
      for {m, n, nz, seed} <- cases do
        t = Ppdu.tx(psdu(n, seed), bw: 2, mcs: m, scrambler: 1 + seed)
        syms = points(t, nz, seed)
        {g0, data} = {Enum.map(hd(syms), &elem(&1, 2)), Enum.drop(syms, 2)}
        {m, t.nsym, syms, DataDec.pairs(g0, data, m)}
      end

    lines = Enum.flat_map(runs, fn {m, ns, syms, _} -> stim(syms, m, ns) end)
    out = Cosim.run([MimoHalow.Hw.Rx.DataDemap], "tb_data_demap.v", lines)
    {ps, ["E " <> early]} = Enum.split(out, -1)
    assert early == "0"

    got = Enum.map(ps, fn l -> [a, b, f, z] = String.split(l); {Cosim.shex(a, 6), Cosim.shex(b, 6), String.to_integer(f), String.to_integer(z)} end)

    want =
      Enum.flat_map(runs, fn {_, _, _, pairs} ->
        n = length(pairs)
        pairs |> Enum.with_index() |> Enum.map(fn {{a, b}, i} -> {a, b, if(i == 0, do: 1, else: 0), if(i == n - 1, do: 1, else: 0)} end)
      end)

    assert length(got) == length(want)
    bad = Enum.zip(got, want) |> Enum.with_index() |> Enum.reject(fn {{g, w}, _} -> g == w end)
    assert bad == [], "#{length(bad)} differ, first #{inspect(Enum.take(bad, 4))}"
  end
end
