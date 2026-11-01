defmodule MimoHalow.Hw.Tx.VPrecoderTest do
  use ExUnit.Case
  import Bitwise
  alias MimoHalow.Model.Fixed.VPrecode
  alias MimoHalow.Model.Mat2
  alias MimoHalow.Model.Mimo.Channel

  # Spec: MimoHalow.Model.Fixed.VPrecode. Table per FFT bin (64-point
  # placeholder plan), steering vectors from SVDs of random 2x2 channels plus
  # a few hand-picked extremes that drive the saturation path.
  defp vtable(seed) do
    {vs, _} =
      Enum.map_reduce(0..63, Channel.rng(seed), fn b, rng ->
        {h, rng} = Channel.rayleigh2(rng)
        {_, _, v} = Mat2.svd(h)
        {{b, Mat2.col(v, 0)}, rng}
      end)

    tab = VPrecode.table(Map.new(vs))
    # Extremes: full-scale v1 (Q1.14 holds up to ~2), and v2 at -1 + j.
    tab
    |> Map.put(0, {{32_767, 0}, {0, 0}})
    |> Map.put(1, {{16_384, 0}, {-16_384, 16_384}})
    |> Map.put(2, {{-32_768, -32_768}, {32_767, -32_768}})
  end

  defp s16(v), do: if(v >= 1 <<< 15, do: v - (1 <<< 16), else: v)
  defp u16(v), do: v &&& 0xFFFF

  @iverilog System.get_env("IVERILOG") ||
              System.find_executable("iverilog") ||
              (File.exists?(Path.expand("~/oss-cad-suite/bin/iverilog")) && Path.expand("~/oss-cad-suite/bin/iverilog")) || nil

  defp run_verilog(tab, pts) do
    dir = Path.join(System.tmp_dir!(), "vpre_cosim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      dut = Path.join(dir, "v_precoder.v")
      File.write!(dut, Hw.emit(Hw.Compile.Elaborate.elaborate(MimoHalow.Hw.Tx.VPrecoder)))
      tb = Path.expand("support/verilog/tb_v_precoder.v", __DIR__)
      out = Path.join(dir, "tb.vvp")
      {log, rc} = System.cmd(@iverilog, ["-g2012", "-o", out, "-s", "tb", tb, dut], stderr_to_stdout: true)
      if rc != 0, do: raise("iverilog: " <> log)

      h = &Integer.to_string(&1, 16)

      writes =
        for {b, {{ar, ai}, {br, bi}}} <- Enum.sort(tab) do
          d = u16(ar) <<< 48 ||| u16(ai) <<< 32 ||| u16(br) <<< 16 ||| u16(bi)
          "#{b} #{h.(d)}\n"
        end

      syms = for {b, {i, q}, l} <- pts, do: "#{b} #{h.(u16(i))} #{h.(u16(q))} #{l}\n"
      File.write!(Path.join(dir, "stim.txt"), ["#{length(writes)}\n", writes, "#{length(syms)}\n", syms])
      vvp = Path.join(Path.dirname(@iverilog), "vvp")
      {_, 0} = System.cmd(vvp, ["-n", out], stderr_to_stdout: true, cd: dir)

      dir
      |> Path.join("out.txt")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn l ->
        [b, ant, i, q, last] = String.split(l)
        {String.to_integer(b), String.to_integer(ant), s16(String.to_integer(i, 16)), s16(String.to_integer(q, 16)),
         String.to_integer(last)}
      end)
    after
      File.rm_rf!(dir)
    end
  end

  test "elaborates and emits" do
    assert Hw.emit(Hw.Compile.Elaborate.elaborate(MimoHalow.Hw.Tx.VPrecoder)) =~ "module v_precoder"
  end

  test "model: precoded pair reproduces s * v (unit-norm v keeps power)" do
    tab = vtable(3)
    s = {10_000, -7_000}

    for b <- 3..63 do
      {{a1r, a1i}, {a2r, a2i}} = VPrecode.apply(tab, b, s)
      p = a1r * a1r + a1i * a1i + a2r * a2r + a2i * a2i
      assert_in_delta p / (10_000 * 10_000 + 7_000 * 7_000), 1.0, 2.0e-3
    end

  end

  @tag :iverilog
  @tag timeout: 600_000
  test "emitted Verilog == Fixed.VPrecode under random backpressure, incl. saturation" do
    if is_nil(@iverilog), do: flunk("iverilog not found")
    tab = vtable(3)
    :rand.seed(:exsss, {4, 5, 6})
    rnd = fn -> :rand.uniform(65_536) - 32_769 end
    pts = for n <- 0..299, do: {rem(n * 37, 64), {rnd.(), rnd.()}, if(rem(n, 50) == 49, do: 1, else: 0)}
    pts = [{0, {32_767, 32_767}, 0}, {2, {-32_768, -32_768}, 0}, {1, {-32_768, 32_767}, 1} | pts]

    want =
      Enum.flat_map(pts, fn {b, s, l} ->
        {{a1r, a1i}, {a2r, a2i}} = VPrecode.apply(tab, b, s)
        [{b, 0, a1r, a1i, 0}, {b, 1, a2r, a2i, l}]
      end)

    got = run_verilog(tab, pts)
    assert length(got) == length(want)
    assert got == want
    # the extremes actually saturated
    assert Enum.any?(got, fn {_, _, i, q, _} -> i in [32_767, -32_768] or q in [32_767, -32_768] end)
  end
end
