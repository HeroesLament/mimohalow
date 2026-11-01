defmodule Mix.Tasks.Mh.Coded do
  @shortdoc "Coded PER (LDPC 648 r1/2) of the 2x2 schemes on a frequency-selective channel"
  @moduledoc """
      mix mh.coded [--bits 4] [--packets 400] [--from 0] [--to 24] [--step 2]
                   [--rms 2.0] [--ntaps 8] [--seed 1]

  `--rms` is the rms delay spread in samples (0 = flat fading).
  """
  use Mix.Task
  alias MimoHalow.Model.Mimo.{Coded, Sim}

  @impl true
  def run(args) do
    {o, _, _} =
      OptionParser.parse(args,
        strict: [bits: :integer, packets: :integer, from: :integer, to: :integer, step: :integer,
                 rms: :float, ntaps: :integer, seed: :integer]
      )

    bits = o[:bits] || 4
    packets = o[:packets] || 400
    seed = o[:seed] || 1
    ch = [rms: o[:rms] || 2.0, ntaps: o[:ntaps] || 8]
    snrs = Enum.to_list((o[:from] || 0)..(o[:to] || 24)//(o[:step] || 2))
    schemes = Coded.schemes()
    {m1, m2} = Sim.mods(bits)

    res =
      for(snr <- snrs, s <- schemes, do: {snr, s})
      |> Task.async_stream(fn {snr, s} -> {{snr, s}, Coded.per(s, snr, bits, packets, seed * 1000 + snr, ch)} end,
        timeout: :infinity,
        max_concurrency: System.schedulers_online()
      )
      |> Map.new(fn {:ok, kv} -> kv end)

    IO.puts("""
    coded PER, LDPC n=648 R=1/2, 2x2 OFDM Rayleigh (#{ch[:ntaps]} taps, rms #{ch[:rms]} samples, 52 sc)
    #{bits} coded bit/use (1 SS #{m1}, 2 SS #{m2}), #{packets} packets/point
    """)

    IO.puts(pad("SNR dB", 7) <> Enum.map_join(schemes, &pad(to_string(&1), 11)))

    for snr <- snrs do
      IO.puts(pad(to_string(snr), 7) <> Enum.map_join(schemes, fn s -> pad(fmt(res[{snr, s}]), 11) end))
    end
  end

  defp fmt({0, _, _}), do: "0"
  defp fmt({e, n, _}), do: :io_lib.format("~.2e", [e / n]) |> to_string()
  defp pad(s, n), do: String.pad_leading(s, n)
end
