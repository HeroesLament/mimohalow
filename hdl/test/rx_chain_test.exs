defmodule MimoHalow.Hw.RxChainTest do
  @moduledoc """
  eig1 end to end: S1G 2 MHz PPDUs from `S1g.Ppdu.tx`, steered per tone by
  the fixed-point precoder (`Fixed.VPrecode`, whole packet incl. LTF, as
  S1G_SHORT beamforming sends it) through a random 2x2 channel with a
  per-symbol common phase drift and AWGN, quantised to FFT-bin integers,
  then the emitted MrcCombiner -> Cpe RTL under iverilog, and the model's
  S1G back end (`Ppdu.decode_points/2`) on what the RTL emits.
  """
  use ExUnit.Case
  alias MimoHalow.Model.{Cx, Mat2}
  alias MimoHalow.Model.Fixed.{Cpe, VPrecode}
  alias MimoHalow.Model.Mimo.Channel
  alias MimoHalow.Model.S1g.{Coding, Params, Ppdu}
  alias MimoHalow.Test.Cosim

  @used Params.used(2)
  @amp 8000.0
  @gain 40.0

  defp psdu(n, seed) do
    :rand.seed(:exsss, {seed, 1, 1})
    body = for _ <- 1..n, into: <<>>, do: <<:rand.uniform(256) - 1>>
    body <> Coding.bits_to_bytes(Coding.fcs(Coding.bytes_to_bits(body)))
  end

  # FFT-domain receive symbols, [chain0, chain1] maps bin => {re, im} ints.
  defp air(t, snr_db, seed) do
    {hs, _} =
      Enum.map_reduce(@used, Channel.rng(seed), fn k, rng ->
        {h, rng} = Channel.rayleigh2(rng)
        {{k, h}, rng}
      end)

    hs = Map.new(hs)
    tab = VPrecode.table(Map.new(hs, fn {k, h} -> {_, _, v} = Mat2.svd(h); {k, Mat2.col(v, 0)} end))
    :rand.seed(:exsss, {seed, 2, 3})
    sigma = @amp * @gain * :math.pow(10, -snr_db / 20) / :math.sqrt(2)
    nz = fn -> {sigma * :rand.normal(), sigma * :rand.normal()} end
    syms = [t.ltf, t.ltf | t.sig ++ t.data]

    syms
    |> Enum.with_index()
    |> Enum.map(fn {x, s} ->
      rotn = Cx.expj(0.4 + 0.03 * s)

      for r <- 0..1 do
        Map.new(0..63, fn b ->
          k = if b < 32, do: b, else: b - 64

          y =
            case x do
              %{^k => xk} ->
                {sr, si} = Cx.scale(xk, @amp)
                {a1, a2} = VPrecode.apply(tab, k, {round(sr), round(si)})
                {{h11, h12}, {h21, h22}} = hs[k]
                {hr1, hr2} = if r == 0, do: {h11, h12}, else: {h21, h22}
                Cx.add(Cx.mul(hr1, Cx.new(elem(a1, 0), elem(a1, 1))), Cx.mul(hr2, Cx.new(elem(a2, 0), elem(a2, 1))))
                |> Cx.scale(@gain)
                |> Cx.mul(rotn)
                |> Cx.add(nz.())

              _ ->
                nz.()
            end

          {b, {round(elem(y, 0)), round(elem(y, 1))}}
        end)
      end
    end)
  end

  defp stream(syms) do
    flush = {[Map.new(0..63, &{&1, {0, 0}})], 2048 + length(syms)}

    for {chains, tag} <- Enum.with_index(syms) ++ [flush], {m, ch} <- Enum.with_index(chains), p <- 0..63 do
      b = Cosim.bitrev6(p)
      {re, im} = m[b]
      "#{b} #{ch} #{tag} #{Cosim.hex(re, 26)} #{Cosim.hex(im, 26)}"
    end
  end

  # Split the RTL output into packets (j restarts at 0), then per symbol points.
  defp packets(rows) do
    rows
    |> Enum.chunk_while([], fn {j, _, _, _, _} = r, acc ->
      case acc do
        [{pj, _, _, _, _} | _] when j < pj -> {:cont, Enum.reverse(acc), [r]}
        _ -> {:cont, [r | acc]}
      end
    end, fn acc -> {:cont, Enum.reverse(acc), []} end)
    |> Enum.map(fn pk ->
      pk
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.map(fn {_j, rs} ->
        rs
        |> Enum.sort_by(&elem(&1, 1))
        |> Enum.map(fn {_, _, xo, yo, g} ->
          k = 2.0 / (Cpe.gain() * max(g, 1))
          {{xo * k, yo * k}, 1.0 / max(g, 1)}
        end)
      end)
    end)
  end

  @tag :iverilog
  @tag timeout: 900_000
  test "S1G 2 MHz MCS4 / MCS7 / MCS8 through precoder + 2x2 + drift -> RTL -> PSDU" do
    cases = [{4, 60, 25.0, 11}, {7, 90, 32.0, 12}, {8, 70, 36.0, 13}]

    txs =
      for {m, n, snr, seed} <- cases do
        p = psdu(n, seed)
        t = Ppdu.tx(p, bw: 2, mcs: m, smoothing: 0, scrambler: 1 + rem(seed * 7, 127))
        {m, p, t, air(t, snr, seed)}
      end

    stim = Enum.flat_map(txs, fn {_, _, _, syms} -> stream(syms) end)

    rows =
      Cosim.run([MimoHalow.Hw.Rx.MrcCombiner, MimoHalow.Hw.Rx.Cpe], "tb_rx_chain.v", stim)
      |> Enum.map(fn l ->
        [j, d, re, im, g, _th] = String.split(l)
        {String.to_integer(j), String.to_integer(d), Cosim.shex(re, 27), Cosim.shex(im, 27), String.to_integer(g)}
      end)

    pks = packets(rows)
    assert length(pks) == length(txs)

    for {{m, p, t, _}, pts} <- Enum.zip(txs, pks) do
      assert length(pts) == Params.sig_syms(2) + t.nsym, "mcs #{m}: symbols out"
      assert {:ok, r} = Ppdu.decode_points(2, pts), "mcs #{m}"
      assert r.fields.mcs == m
      assert r.fields.smoothing == 0
      assert r.psdu == p, "mcs #{m}: PSDU"
      assert r.fcs_ok
    end

  end
end
