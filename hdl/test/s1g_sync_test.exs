defmodule MimoHalow.Hw.S1gSyncTest do
  @moduledoc """
  OcuSync's `Hw.RxSync` (StfDetector -> LtfSync) on S1G 2 MHz S1G_SHORT
  packets at 2 MS/s: the STF (2 x 80 samples, period 16) and LTF1 (DGI 32 +
  2 x 64, 56-tone LTF whose +-1..26 part is the L-LTF) have the 11a L-STF /
  L-LTF layout, so the first LTF symbol is at n0 + 192 and the block's
  `td + 82 + ts_off` must land there.
  """
  use ExUnit.Case
  import Bitwise
  alias MimoHalow.Model.S1g.{Coding, Ppdu}
  alias MimoHalow.Test.Cosim

  defp frame(n0, cfo, amp, noise, mcs, seed) do
    :rand.seed(:exsss, {seed, 3, 5})
    body = for _ <- 1..80, into: <<>>, do: <<:rand.uniform(256) - 1>>
    p = body <> Coding.bits_to_bytes(Coding.fcs(Coding.bytes_to_bits(body)))
    t = Ppdu.tx(p, bw: 2, mcs: mcs)
    sig = List.duplicate({0.0, 0.0}, n0) ++ t.samples ++ List.duplicate({0.0, 0.0}, 600)

    sig
    |> Enum.with_index()
    |> Enum.map(fn {{a, b}, n} ->
      w = 2 * :math.pi() * cfo * n
      {x, y} = {a * :math.cos(w) - b * :math.sin(w), a * :math.sin(w) + b * :math.cos(w)}
      nz = fn -> round(noise * :rand.normal()) end
      {clamp(round(amp * x) + nz.() + 150), clamp(round(amp * y) + nz.() - 90)}
    end)
  end

  defp clamp(v), do: v |> max(-2048) |> min(2047)
  defp wrap(v, bits), do: (m = v &&& (1 <<< bits) - 1; if m >= 1 <<< (bits - 1), do: m - (1 <<< bits), else: m)

  defp run(x, emin) do
    stim = Enum.map(x, fn {i, q} -> "#{Cosim.hex(i, 12)} #{Cosim.hex(q, 12)}" end)

    lines = Cosim.run([Hw.RxSync], "tb_rx_sync.v", stim, header: "#{length(x)} #{emin}")
    {syncs, ["C " <> _]} = Enum.split(lines, -1)

    Enum.map(syncs, fn l ->
      [td, ts, _th, _th2, dp] = String.split(l)
      {String.to_integer(td), String.to_integer(ts), wrap(String.to_integer(dp, 16), 24) / 16_777_216}
    end)
  end

  @tag :iverilog
  @tag timeout: 900_000
  test "OcuSync RxSync locks on S1G 2 MHz short preambles: timing at LTF1, CFO" do
    # cfo in cycles/sample at 2 MS/s: 0.0023 = 4.6 kHz, -0.011 = -22 kHz (~ +-10 ppm at 2.4 GHz is +-24 kHz)
    cases = [{1200, 0.0023, 500.0, 20.0, 0, 1}, {300, -0.011, 300.0, 15.0, 4, 2}, {400, 0.0, 800.0, 30.0, 7, 3}]

    {x, starts} =
      Enum.reduce(cases, {[], []}, fn {n0, cfo, amp, nz, mcs, seed}, {acc, st} ->
        f = frame(n0, cfo, amp, nz, mcs, seed)
        {acc ++ f, st ++ [{length(acc) + n0 + 192, cfo}]}
      end)

    got = run(x, 20 * 64)
    assert length(got) == length(cases), inspect(got)

    for {{td, ts, est}, {want, cfo}} <- Enum.zip(got, starts) do
      assert (td + 82 + ts) in (want - 1)..(want + 1), "LTF1 at #{td + 82 + ts}, want #{want}"
      assert_in_delta est, cfo, 1.0e-4
    end
  end
end
