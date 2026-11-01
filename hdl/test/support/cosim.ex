defmodule MimoHalow.Test.Cosim do
  @moduledoc """
  iverilog co-simulation plumbing for the hdl tests: emit components, compile
  them with a bench from `test/support/verilog`, run it on a stim file, return
  the bench's out.txt lines.
  """
  import Bitwise

  def iverilog do
    System.get_env("IVERILOG") || System.find_executable("iverilog") ||
      (File.exists?(Path.expand("~/oss-cad-suite/bin/iverilog")) && Path.expand("~/oss-cad-suite/bin/iverilog")) || nil
  end

  @doc "Run `bench` (file name) against `mods` (components) with stim `lines`."
  def run(mods, bench, stim_lines) do
    iv = iverilog() || raise "iverilog not found"
    dir = Path.join(System.tmp_dir!(), "mh_cosim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      duts =
        for m <- mods do
          f = Path.join(dir, "#{inspect(m)}.v")
          File.write!(f, Hw.emit(Hw.Compile.Elaborate.elaborate(m)))
          f
        end

      tb = Path.expand("verilog/#{bench}", __DIR__)
      out = Path.join(dir, "tb.vvp")
      {log, rc} = System.cmd(iv, ["-g2012", "-o", out, "-s", "tb", tb | duts], stderr_to_stdout: true)
      if rc != 0, do: raise("iverilog: " <> log)
      File.write!(Path.join(dir, "stim.txt"), ["#{length(stim_lines)}\n" | Enum.map(stim_lines, &[&1, "\n"])])
      {log, rc} = System.cmd(Path.join(Path.dirname(iv), "vvp"), ["-n", out], stderr_to_stdout: true, cd: dir)
      if rc != 0, do: raise("vvp: " <> log)
      dir |> Path.join("out.txt") |> File.read!() |> String.split("\n", trim: true)
    after
      File.rm_rf!(dir)
    end
  end

  @doc "w-bit two's complement hex of v."
  def hex(v, w), do: v |> band((1 <<< w) - 1) |> Integer.to_string(16)

  @doc "Signed value of a w-bit hex string."
  def shex(s, w) do
    v = String.to_integer(s, 16)
    if v >= 1 <<< (w - 1), do: v - (1 <<< w), else: v
  end

  def bitrev6(i), do: for(b <- 0..5, reduce: 0, do: (acc -> acc ||| (i >>> b &&& 1) <<< (5 - b)))
end
