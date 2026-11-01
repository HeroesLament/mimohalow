defmodule Mix.Tasks.Mh.Trace do
  @shortdoc "Coded PER of the 2x2 schemes on measured channels (sounder captures)"
  @moduledoc """
      mix mh.trace --cur rr2477_r3 [--stale rr2477_r2,rr2477_r1] [--dir ~/.cache/oxl/sounder]
                   [--bits 4] [--packets 150] [--from -2] [--to 18] [--step 2]

  For each link of round `--cur`: channel stats, then the SNR (dB) at PER 1e-1
  of every scheme, plus eigen / SVD beamforming with the precoder computed
  from each `--stale` round's channel for the same link (explicit feedback
  that old). SNR is per receive antenna at unit mean per-entry channel power.
  """
  use Mix.Task
  alias MimoHalow.Model.Mimo.{Coded, Sim, Trace}

  @impl true
  def run(args) do
    {o, _, _} =
      OptionParser.parse(args,
        strict: [dir: :string, cur: :string, stale: :string, bits: :integer, packets: :integer,
                 from: :integer, to: :integer, step: :integer]
      )

    dir = Path.expand(o[:dir] || "~/.cache/oxl/sounder")
    bits = o[:bits] || 4
    packets = o[:packets] || 150
    snrs = Enum.to_list((o[:from] || -2)..(o[:to] || 18)//(o[:step] || 2))
    stale_tags = if o[:stale], do: String.split(o[:stale], ","), else: []

    cur = Trace.load_round(dir, o[:cur])
    stale = Map.new(stale_tags, &{&1, Trace.load_round(dir, &1)})
    links = cur |> Map.keys() |> Enum.sort()

    cols =
      Enum.map(Coded.schemes(), &{&1, nil}) ++
        for(t <- stale_tags, s <- [:eigen_1ss, :svd_2ss], do: {s, t})

    jobs =
      for l <- links, {s, t} <- cols, snr <- snrs, t == nil or Map.has_key?(stale[t], l), do: {l, s, t, snr}

    res =
      jobs
      |> Task.async_stream(
        fn {l, s, t, snr} ->
          hs = Trace.subcarriers(cur[l])
          ch = if t, do: [hs: hs, hs_tx: Trace.subcarriers(stale[t][l])], else: [hs: hs]
          {{l, s, t, snr}, Coded.per(s, snr, bits, packets, 7000 + snr, ch)}
        end,
        timeout: :infinity,
        max_concurrency: System.schedulers_online()
      )
      |> Map.new(fn {:ok, kv} -> kv end)

    {m1, m2} = Sim.mods(bits)
    IO.puts("SNR (dB) at PER 1e-1, LDPC 648 r1/2, #{bits} b/use (1 SS #{m1}, 2 SS #{m2}), #{packets} packets/point, measured channels of #{o[:cur]}\n")

    head = Enum.map_join(cols, fn {s, t} -> pad(short(s) <> if(t, do: "@" <> suffix(t), else: ""), 11) end)
    IO.puts(pad("link", 6) <> pad("entry pwr dB", 24) <> pad("spread", 8) <> head)

    for l = {tx, rx} <- links do
      st = Trace.stats(Trace.subcarriers(cur[l]))
      name = Trace.label(tx) <> "->" <> Trace.label(rx)

      row =
        Enum.map_join(cols, fn {s, t} ->
          curve = for snr <- snrs, r = res[{l, s, t, snr}], r != nil, do: {snr, elem(r, 0) / elem(r, 1)}
          pad(at_per(curve, 0.1, snrs), 11)
        end)

      IO.puts(pad(name, 6) <> pad(inspect(st.power_db), 24) <> pad(to_string(st.eig_spread_db), 8) <> row)
    end
  end

  defp at_per([], _, _), do: "-"

  defp at_per(curve, target, snrs) do
    case Enum.find_index(curve, fn {_, p} -> p <= target end) do
      nil -> ">" <> to_string(List.last(snrs))
      0 -> "<" <> to_string(hd(snrs))
      i ->
        {s0, p0} = Enum.at(curve, i - 1)
        {s1, p1} = Enum.at(curve, i)
        l = fn p -> :math.log10(max(p, 1.0e-4)) end
        x = s0 + (s1 - s0) * (l.(target) - l.(p0)) / (l.(p1) - l.(p0))
        :erlang.float_to_binary(x, decimals: 1)
    end
  end

  defp short(:siso), do: "siso"
  defp short(:mrc_1x2), do: "mrc"
  defp short(:alamouti), do: "stbc"
  defp short(:eigen_1ss), do: "eig1"
  defp short(:sm_mmse), do: "sm_mmse"
  defp short(:sm_ml), do: "sm_ml"
  defp short(:svd_2ss), do: "svd2"

  defp suffix(t), do: t |> String.split("_") |> List.last()
  defp pad(s, n), do: String.pad_leading(s, n)
end
