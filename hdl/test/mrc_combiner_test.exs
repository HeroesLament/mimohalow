defmodule MimoHalow.Hw.Rx.MrcCombinerTest do
  use ExUnit.Case
  import Bitwise
  alias MimoHalow.Model.Fixed.Mrc

  # Spec: MimoHalow.Model.Fixed.Mrc on the S1G 2 MHz tone plan that
  # scripts/gen_mrc_combiner.exs elaborates (MimoHalow.Model.S1g.Params).
  alias MimoHalow.Model.S1g.Params
  @used_k Params.used(2)
  @data_k Params.data(2)
  @pilot_k Params.pilots(2)
  @ltf_k Params.ltf(2)
  @sign @ltf_k
  @dix @data_k |> Enum.with_index() |> Map.new(fn {k, d} -> {k, {0, d}} end)
  @pix @pilot_k |> Enum.with_index() |> Map.new(fn {k, d} -> {k, {1, d}} end)
  @idx Map.merge(@dix, @pix)

  defp bin(k), do: Params.bin(k, 2)
  defp bitrev6(i), do: for(b <- 0..5, reduce: 0, do: (acc -> acc ||| (i >>> b &&& 1) <<< (5 - b)))

  # Two-chain PPDU in the FFT domain: independent per-chain channels, two LTF
  # symbols, data symbols. Each symbol is [chain0, chain1], maps bin => {re, im}.
  defp ppdu(amp, ndata, qam16?, seed) do
    :rand.seed(:exsss, {seed, seed + 3, seed + 5})
    nz = fn s -> round((:rand.uniform() - 0.5) * 2 * s) end

    hs =
      for _r <- 0..1 do
        Map.new(@used_k, fn k ->
          a = amp * (0.3 + :rand.uniform())
          w = :rand.uniform() * 6.283
          {k, {a * :math.cos(w), a * :math.sin(w)}}
        end)
      end

    noise = amp * 0.02
    filler = fn -> Map.new(0..63, fn b -> {b, {nz.(noise), nz.(noise)}} end) end

    sym = fn xk ->
      for h <- hs do
        Enum.reduce(@used_k, filler.(), fn k, m ->
          {xr, xi} = xk.(k)
          {hr, hi} = h[k]
          Map.put(m, bin(k), {round(hr * xr - hi * xi) + nz.(noise), round(hr * xi + hi * xr) + nz.(noise)})
        end)
      end
    end

    lv = if qam16?, do: [-3, -1, 1, 3], else: [-1, 1]
    sc = if qam16?, do: 1 / :math.sqrt(10), else: 1 / :math.sqrt(2)
    ltf = fn -> sym.(fn k -> {1.0 * @ltf_k[k], 0.0} end) end

    data =
      for _j <- 1..ndata do
        xs = Map.new(@used_k, fn k -> {k, {Enum.random(lv) * sc, Enum.random(lv) * sc}} end)
        sym.(&xs[&1])
      end

    [ltf.(), ltf.() | data]
  end

  defp model([l1, l2 | data]) do
    by_k = fn m -> Map.new(@used_k, fn k -> {k, m[bin(k)]} end) end
    est = Mrc.estimate(Enum.map(l1, by_k), Enum.map(l2, by_k), @used_k, @sign)

    out =
      for {y, j} <- Enum.with_index(data), {k, {{dr, di}, g}} <- Mrc.combine(est, Enum.map(y, by_k), @used_k) do
        {pil, d} = @idx[k]
        {j, pil, d, dr, di, g}
      end

    {est.sh, est.noise, Enum.sort(out)}
  end

  # "bin chain tag re im" lines in FFT output order, chain 0 then chain 1 per
  # symbol; a flush symbol (chain 0) after the PPDU.
  defp stream(syms) do
    flush = {[Map.new(0..63, &{&1, {0, 0}})], 2048 + length(syms)}

    for {chains, tag} <- Enum.with_index(syms) ++ [flush], {m, ch} <- Enum.with_index(chains), p <- 0..63 do
      b = bitrev6(p)
      {re, im} = m[b]
      {b, ch, tag, re, im}
    end
  end

  @iverilog System.get_env("IVERILOG") ||
              System.find_executable("iverilog") ||
              (File.exists?(Path.expand("~/oss-cad-suite/bin/iverilog")) && Path.expand("~/oss-cad-suite/bin/iverilog")) || nil

  defp s26(v), do: if(v >= 1 <<< 25, do: v - (1 <<< 26), else: v)

  defp run_verilog(lines) do
    dir = Path.join(System.tmp_dir!(), "mrc_cosim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      dut = Path.join(dir, "mrc_combiner.v")
      File.write!(dut, Hw.emit(Hw.Compile.Elaborate.elaborate(MimoHalow.Hw.Rx.MrcCombiner)))
      tb = Path.expand("support/verilog/tb_mrc_combiner.v", __DIR__)
      out = Path.join(dir, "tb.vvp")
      {log, rc} = System.cmd(@iverilog, ["-g2012", "-o", out, "-s", "tb", tb, dut], stderr_to_stdout: true)
      if rc != 0, do: raise("iverilog: " <> log)

      h = fn v -> v |> band(0x3FFFFFF) |> Integer.to_string(16) end

      File.write!(Path.join(dir, "stim.txt"), [
        "#{length(lines)}\n" | Enum.map(lines, fn {b, ch, t, re, im} -> "#{b} #{ch} #{t} #{h.(re)} #{h.(im)}\n" end)
      ])

      vvp = Path.join(Path.dirname(@iverilog), "vvp")
      {_, 0} = System.cmd(vvp, ["-n", out], stderr_to_stdout: true, cd: dir)
      ls = dir |> Path.join("out.txt") |> File.read!() |> String.split("\n", trim: true)
      {es, ["N " <> n]} = Enum.split(ls, -1)

      es =
        Enum.map(es, fn l ->
          [j, d, re, im, g, last, pil] = String.split(l)
          {String.to_integer(j), String.to_integer(pil), String.to_integer(d), s26(String.to_integer(re, 16)),
           s26(String.to_integer(im, 16)), String.to_integer(g), String.to_integer(last)}
        end)

      [sh, noise] = n |> String.split() |> Enum.map(&String.to_integer/1)
      {es, sh, noise}
    after
      File.rm_rf!(dir)
    end
  end

  test "elaborates and emits" do
    assert Hw.emit(Hw.Compile.Elaborate.elaborate(MimoHalow.Hw.Rx.MrcCombiner)) =~ "module mrc_combiner"
  end

  test "model: combined points land on the constellation (scale > 0 and = 0)" do
    for {amp, q16, seed} <- [{300_000.0, true, 1}, {20_000.0, false, 2}] do
      {sh, _noise, out} = model(ppdu(amp, 3, q16, seed))
      assert (sh > 0) == (amp > 100_000)
      lv = if q16, do: Enum.map([-3, -1, 1, 3], &(&1 / :math.sqrt(10))), else: [-1 / :math.sqrt(2), 1 / :math.sqrt(2)]

      for {_j, 0, _d, dr, di, g} <- out do
        # D / G = x / 2 (Hn carries L1 + L2 = 2 H)
        {x, y} = {2 * dr / g, 2 * di / g}
        assert Enum.min(Enum.map(lv, &abs(&1 - x))) < 0.1
        assert Enum.min(Enum.map(lv, &abs(&1 - y))) < 0.1
      end
    end
  end

  @tag :iverilog
  @tag timeout: 900_000
  test "emitted Verilog == Fixed.Mrc: two PPDUs (16-QAM scale > 0, QPSK scale = 0), flush dropped" do
    if is_nil(@iverilog), do: flunk("iverilog not found")
    a = ppdu(300_000.0, 3, true, 1)
    b = ppdu(20_000.0, 2, false, 2)
    {sha, _na, outa} = model(a)
    {shb, nb, outb} = model(b)
    assert sha > 0 and shb == 0

    {got, sh, noise} = run_verilog(stream(a) ++ stream(b))
    {ga, gb} = Enum.split(got, length(outa))

    for {g, want} <- [{ga, outa}, {gb, outb}] do
      assert Enum.sort(Enum.map(g, fn {j, p, d, r, i, gg, _} -> {j, p, d, r, i, gg} end)) == want

      # Every used tone once per symbol; e_last exactly on the final output.
      for {_j, rows} <- Enum.group_by(g, &elem(&1, 0)) do
        assert length(rows) == length(@used_k)
        assert Enum.count(rows, &(elem(&1, 1) == 1)) == length(@pilot_k)
        assert Enum.map(rows, &elem(&1, 6)) == List.duplicate(0, length(rows) - 1) ++ [1]
      end
    end

    assert {sh, noise} == {shb, nb}
  end
end
