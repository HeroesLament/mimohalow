defmodule MimoHalow.Hw.Rx.DcBlockTest do
  use ExUnit.Case
  alias MimoHalow.Model.Fixed.DcBlock
  alias MimoHalow.Test.Cosim

  defp clamp(v), do: v |> max(-2048) |> min(2047)

  # DC steps (the AD9363's ~66 counts, and large ones), a tone over DC, noise
  # over DC, and rail-to-rail squares (drive y past +-2047 for saturation).
  defp stream(kind, n) do
    :rand.seed(:exsss, {kind, 7, 7})

    for t <- 0..(n - 1) do
      case kind do
        0 -> if t < 5000, do: 66, else: -700
        1 -> round(55 + 900 * :math.cos(2 * :math.pi() * 400_000 * t / 8.0e6))
        2 -> round(-37 + 300 * :rand.normal())
        3 -> if rem(div(t, 5000), 2) == 0, do: 2047, else: -2048
      end
      |> clamp()
    end
  end

  @tag :iverilog
  test "emitted Verilog == Fixed.DcBlock (DC steps, tone, noise, saturation)" do
    n = 40_000
    xs = for k <- 0..3, do: stream(k, n)

    stim =
      xs
      |> Enum.zip()
      |> Enum.map(fn {a, b, c, d} -> Enum.map_join([a, b, c, d], " ", &Cosim.hex(&1, 12)) end)

    got =
      Cosim.run([MimoHalow.Hw.Rx.DcBlock], "tb_dc_block.v", stim)
      |> Enum.map(fn l -> l |> String.split() |> Enum.map(&Cosim.shex(&1, 12)) end)

    want = xs |> Enum.map(&DcBlock.run/1) |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
    assert length(got) == length(want)
    bad = Enum.zip(got, want) |> Enum.with_index() |> Enum.reject(fn {{g, w}, _} -> g == w end)
    assert bad == [], "#{length(bad)} differ, first #{inspect(Enum.take(bad, 3))}"

    # The DC step settles: the last 2000 samples of stream 0 sit at 0.
    tail0 = got |> Enum.take(-2000) |> Enum.map(&hd/1)
    assert Enum.all?(tail0, &(abs(&1) <= 1)), inspect(Enum.take(tail0, 5))
    # The rails saturate (x - d past +-2047 right after each square edge).
    assert Enum.any?(got, fn [_, _, _, d] -> d in [2047, -2048] end)
  end

  test "model: a DC of 66 counts decays to 0 within ~6 time constants" do
    ys = DcBlock.run(List.duplicate(66, 30_000))
    assert hd(ys) == 66
    assert ys |> Enum.drop(25_000) |> Enum.all?(&(&1 in 0..1))
  end
end
