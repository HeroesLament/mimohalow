defmodule MimoHalow.Model.MimoTest do
  use ExUnit.Case, async: true
  alias MimoHalow.Model.{Mat2, Qam}
  alias MimoHalow.Model.Mimo.{Channel, Detect, Sim}

  test "every scheme is exact without noise" do
    for s <- Sim.schemes(), bits <- [2, 4, 8] do
      {m1, m2} = Sim.mods(bits)

      Enum.reduce(1..50, Channel.rng(11), fn _, rng ->
        {sent, got, rng} = Sim.trial(s, 1.0e-12, m1, m2, rng)
        assert sent == got, "#{s} #{bits}"
        rng
      end)
    end
  end

  test "ML LLR signs agree with the ML decision" do
    Enum.reduce(1..100, Channel.rng(5), fn _, rng ->
      {h, rng} = Channel.rayleigh2(rng)
      {b, rng} = Channel.bits(rng, 4)
      [p1, p2] = Qam.map(b, :qpsk)
      {n, rng} = Channel.noise2(rng, 0.05)
      y = Mat2.vadd(Mat2.mulv(h, {p1, p2}), n)
      hard = Detect.ml_bits(h, y, :qpsk)
      soft = Detect.ml_llrs(h, y, 0.05, :qpsk) |> Enum.map(&if(&1 >= 0, do: 0, else: 1))
      assert hard == soft
      rng
    end)
  end

  test "diversity: Alamouti and MRC beat SISO; ML beats MMSE; eigenmode beats Alamouti" do
    ber = fn s, snr -> Sim.ber(s, snr, 4, 3000, 42) end
    assert ber.(:alamouti, 18) < ber.(:siso, 18) / 4
    assert ber.(:mrc_1x2, 18) < ber.(:siso, 18) / 4
    assert ber.(:sm_ml, 18) < ber.(:sm_mmse, 18)
    assert ber.(:eigen_1ss, 18) < ber.(:alamouti, 18)
  end

  test "mean strongest eigenmode gain of 2x2 Rayleigh is ~3.5 (5.4 dB)" do
    {sum, _} =
      Enum.reduce(1..5000, {0.0, Channel.rng(9)}, fn _, {acc, rng} ->
        {h, rng} = Channel.rayleigh2(rng)
        {_, {s1, _}, _} = Mat2.svd(h)
        {acc + s1 * s1, rng}
      end)

    assert_in_delta sum / 5000, 3.5, 0.15
  end
end
