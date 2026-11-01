defmodule MimoHalow.Hw.Rx.Decim4Test do
  use ExUnit.Case
  alias MimoHalow.Model.Fixed.Decim4
  alias MimoHalow.Test.Cosim

  defp clamp(v), do: v |> max(-2048) |> min(2047)

  # Four different streams: in-band and out-of-band tones, noise, full-scale square bursts.
  defp stream(kind, n) do
    :rand.seed(:exsss, {kind, 5, 5})

    for t <- 0..(n - 1) do
      case kind do
        0 -> round(900 * :math.cos(2 * :math.pi() * 400_000 * t / 8.0e6) + 700 * :math.cos(2 * :math.pi() * 2_500_000 * t / 8.0e6))
        1 -> round(600 * :rand.normal())
        2 -> if rem(div(t, 37), 2) == 0, do: 2047, else: -2048
        3 -> round(1500 * :math.sin(2 * :math.pi() * 870_000 * t / 8.0e6) + 400 * :rand.normal())
      end
      |> clamp()
    end
  end

  @tag :iverilog
  test "emitted Verilog == Fixed.Decim4 on four streams (tones, noise, saturation)" do
    n = 3000
    xs = for k <- 0..3, do: stream(k, n)

    stim =
      xs
      |> Enum.zip()
      |> Enum.map(fn {a, b, c, d} -> Enum.map_join([a, b, c, d], " ", &Cosim.hex(&1, 12)) end)

    got =
      Cosim.run([MimoHalow.Hw.Rx.Decim4], "tb_decim4.v", stim)
      |> Enum.map(fn l -> l |> String.split() |> Enum.map(&Cosim.shex(&1, 12)) end)

    want = xs |> Enum.map(&Decim4.run/1) |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
    assert length(got) == length(want)
    bad = Enum.zip(got, want) |> Enum.with_index() |> Enum.reject(fn {{g, w}, _} -> g == w end)
    assert bad == [], "#{length(bad)} differ, first #{inspect(Enum.take(bad, 3))}"
    # the square bursts hit both rails
    assert Enum.any?(got, fn [_, _, c, _] -> c in [2047, -2048] end)
  end
end
