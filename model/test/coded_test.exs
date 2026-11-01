defmodule MimoHalow.Model.CodedTest do
  use ExUnit.Case, async: true
  alias MimoHalow.Model.{Demap, Ldpc, Qam}
  alias MimoHalow.Model.Mimo.{Channel, Coded, OfdmChannel}

  test "LDPC 648 r1/2 encodes to a zero syndrome" do
    {info, _} = Channel.bits(Channel.rng(2), Ldpc.code().k)
    assert Ldpc.syndrome_weight(Ldpc.encode(info)) == 0
  end

  test "soft demapper signs match the hard slicer" do
    for mod <- Qam.mods(), {bits, p} <- Qam.constellation(mod) do
      soft = Demap.llrs(p, 0.1, mod) |> Enum.map(&if(&1 > 0, do: 0, else: 1))
      assert soft == bits
    end
  end

  test "OFDM channel: unit average power per entry" do
    {sum, _} =
      Enum.reduce(1..300, {0.0, Channel.rng(4)}, fn _, {acc, rng} ->
        {hs, rng} = OfdmChannel.draw(rng, OfdmChannel.data_subcarriers())
        p = hs |> Enum.map(fn {{a, _}, _} -> MimoHalow.Model.Cx.abs2(a) end) |> Enum.sum()
        {acc + p / length(hs), rng}
      end)

    assert_in_delta sum / 300, 1.0, 0.1
  end

  test "every scheme decodes every packet at high SNR" do
    for s <- Coded.schemes(), bits <- [2, 4] do
      assert {0, 4, _} = Coded.per(s, 40, bits, 4, 3), "#{s} #{bits}"
    end
  end
end
