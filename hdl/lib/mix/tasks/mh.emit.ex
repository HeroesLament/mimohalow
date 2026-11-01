defmodule Mix.Tasks.Mh.Emit do
  @shortdoc "Emit the LibreSDR board top (mimohalow PHY) as one Verilog file"
  @moduledoc """
  Elaborate and emit `MimoHalow.Designs.LibreSDR.Top` (or `--top Module`)
  to a single flattened Verilog file, the input to oxibit-synth.

      mix mh.emit                       # -> build/libresdr_mh.v
      mix mh.emit --out /tmp/x.v
      mix mh.emit --top MimoHalow.Hw.PhyHost --out build/phy_host.v

  Prints the output path, its size and sha256 (the build's identity).
  """
  use Mix.Task

  @default_top MimoHalow.Designs.LibreSDR.Top

  @impl true
  def run(argv) do
    {opts, _, bad} = OptionParser.parse(argv, strict: [out: :string, top: :string])
    if bad != [], do: Mix.raise("unknown options #{inspect(bad)}")
    Mix.Task.run("compile")

    top = if t = opts[:top], do: Module.concat([t]), else: @default_top
    Code.ensure_loaded?(top) || Mix.raise("no module #{inspect(top)}")
    out = Path.expand(opts[:out] || "build/libresdr_mh.v")
    File.mkdir_p!(Path.dirname(out))

    v = Hw.emit(Hw.Compile.Elaborate.elaborate(top))
    File.write!(out, v)
    sha = :crypto.hash(:sha256, v) |> Base.encode16(case: :lower)
    Mix.shell().info("#{out} #{byte_size(v)} bytes sha256 #{sha}")
  end
end
