defmodule Mix.Tasks.Mh.Sim do
  @shortdoc "Uncoded BER of the 2x2 schemes vs SNR (Rayleigh)"
  @moduledoc """
      mix mh.sim [--bits 4] [--trials 4000] [--from 0] [--to 30] [--step 3] [--seed 1]

  `--bits` is bits per channel use (2, 4 or 8): one-stream schemes use that
  many bits per symbol, two-stream schemes half per stream.
  """
  use Mix.Task
  alias MimoHalow.Model.Mimo.Sim

  @impl true
  def run(args) do
    {o, _, _} =
      OptionParser.parse(args,
        strict: [bits: :integer, trials: :integer, from: :integer, to: :integer, step: :integer, seed: :integer]
      )

    bits = o[:bits] || 4
    trials = o[:trials] || 4000
    seed = o[:seed] || 1
    snrs = Enum.to_list((o[:from] || 0)..(o[:to] || 30)//(o[:step] || 3))
    schemes = Sim.schemes()
    {m1, m2} = Sim.mods(bits)

    res =
      for(snr <- snrs, s <- schemes, do: {snr, s})
      |> Task.async_stream(fn {snr, s} -> {{snr, s}, Sim.ber(s, snr, bits, trials, seed * 1000 + snr)} end,
        timeout: :infinity,
        max_concurrency: System.schedulers_online()
      )
      |> Map.new(fn {:ok, kv} -> kv end)

    IO.puts("uncoded BER, i.i.d. Rayleigh, #{bits} bit/use (1 SS #{m1}, 2 SS #{m2}), #{trials} trials/point\n")
    IO.puts(pad("SNR dB", 7) <> Enum.map_join(schemes, &pad(to_string(&1), 11)))

    for snr <- snrs do
      IO.puts(pad(to_string(snr), 7) <> Enum.map_join(schemes, &pad(fmt(res[{snr, &1}]), 11)))
    end
  end

  defp fmt(+0.0), do: "0"
  defp fmt(x), do: :io_lib.format("~.2e", [x]) |> to_string()
  defp pad(s, n), do: String.pad_leading(s, n)
end
