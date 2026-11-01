defmodule Mix.Tasks.Mh.Sounder.Analyse do
  @shortdoc "Re-analyse a saved sounder capture (.etf written by the controller)"
  @moduledoc "    mix mh.sounder.analyse CAP.etf [--profile]"
  use Mix.Task
  alias MimoHalow.Model.Sounder

  @impl true
  def run(args) do
    {o, [file], _} = OptionParser.parse(args, strict: [profile: :boolean])
    d = file |> File.read!() |> :erlang.binary_to_term()

    for {b, {:ok, c}} <- d.caps do
      cap = Sounder.decode_capture(c.u64)
      IO.puts("== #{b}  holes #{c.seq.holes}")

      if o[:profile] do
        prof = Sounder.timing_profile(cap)
        top = prof |> Enum.sort_by(&(-elem(&1, 2))) |> Enum.take(5)
        IO.inspect(Enum.map(top, fn {dd, sc, xc} -> {dd, Float.round(sc, 3), Float.round(xc / 1.0e6, 2)} end), label: "top xcorr {d, sc, xc/1e6}")
      end

      a = Sounder.analyse(cap)
      IO.inspect(Sounder.summary(a), label: "summary")
      IO.inspect(Enum.map(a.periods, & &1.start), label: "starts", limit: 20)
    end
  end
end
