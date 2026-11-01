defmodule MimoHalow.Hw.Rx.Eig1Test do
  @moduledoc """
  The eig1 receiver from samples: S1G 2 MHz S1G_SHORT PPDUs steered per
  tone by the principal right singular vector of a 3-tap 2x2 multipath
  channel (the whole packet, as S1G_SHORT beamforming sends it), CFO, DC,
  noise, 12-bit samples on both chains -> `Hw.Rx.Eig1` under iverilog ->
  the model's S1G back end -> PSDU.
  """
  use ExUnit.Case
  alias MimoHalow.Model.{Cx, Fft, Mat2}
  alias MimoHalow.Model.Fixed.Cpe
  alias MimoHalow.Model.S1g.{Coding, Params, Ppdu}
  alias MimoHalow.Test.Cosim

  @n 64
  @gi 16

  defp psdu(n, seed) do
    :rand.seed(:exsss, {seed, 1, 1})
    body = for _ <- 1..n, into: <<>>, do: <<:rand.uniform(256) - 1>>
    body <> Coding.bits_to_bytes(Coding.fcs(Coding.bytes_to_bits(body)))
  end

  defp channel(seed) do
    :rand.seed(:exsss, {seed, 4, 4})
    pw = [1.0, 0.35, 0.12]

    for _r <- 0..1 do
      for _t <- 0..1 do
        Enum.map(pw, fn p -> s = :math.sqrt(p / 2 / 1.47); {s * :rand.normal(), s * :rand.normal()} end)
      end
    end
  end

  defp hk(taps, k) do
    for row <- taps do
      for tl <- row do
        tl |> Enum.with_index() |> Enum.map(fn {h, l} -> Cx.mul(h, Cx.expj(-2 * :math.pi() * k * l / @n)) end) |> Cx.sum()
      end
    end
    |> then(fn [[a, b], [c, d]] -> {{a, b}, {c, d}} end)
  end

  defp time(tones, field) do
    g = Params.norm(field, 2) * @n
    v = for i <- 0..(@n - 1), do: Map.get(tones, if(i < 32, do: i, else: i - @n), Cx.zero())
    v |> Fft.ifft() |> Enum.map(&Cx.scale(&1, g))
  end

  defp cp(t, l), do: Enum.take(t, -l) ++ t

  # Per-antenna baseband of a steered PPDU.
  defp antennas(t, vs) do
    steer = fn tones, a -> Map.new(tones, fn {k, x} -> {k, Cx.mul(x, elem(vs[k], a))} end) end

    for a <- 0..1 do
      stf = cp(time(steer.(t.stf, a), :stf), @gi)
      ltf = time(steer.(t.ltf, a), :ltf)
      stf ++ stf ++ cp(ltf ++ ltf, 2 * @gi) ++
        Enum.flat_map(t.sig, &cp(time(steer.(&1, a), :sig), @gi)) ++
        Enum.flat_map(t.data, &cp(time(steer.(&1, a), :data), @gi))
    end
  end

  defp conv(xs, taps) do
    t = List.to_tuple(xs)

    for n <- 0..(tuple_size(t) - 1) do
      taps |> Enum.with_index() |> Enum.map(fn {h, l} -> if n - l >= 0, do: Cx.mul(h, elem(t, n - l)), else: Cx.zero() end) |> Cx.sum()
    end
  end

  defp frame({m, len, snr, cfo, seed}) do
    p = psdu(len, seed)
    t = Ppdu.tx(p, bw: 2, mcs: m, smoothing: 0, scrambler: 1 + rem(seed * 11, 127))
    taps = channel(seed)
    vs = Map.new(Params.used(2), fn k -> {_, _, v} = Mat2.svd(hk(taps, k)); {k, Mat2.col(v, 0)} end)
    [a0, a1] = antennas(t, vs)
    pad = fn xs -> List.duplicate(Cx.zero(), 300) ++ xs ++ List.duplicate(Cx.zero(), 400) end
    :rand.seed(:exsss, {seed, 8, 8})
    amp = 600.0
    sigma = amp * :math.pow(10, -snr / 20) / :math.sqrt(2)

    ys =
      for [h0, h1] <- taps do
        Enum.zip_with(conv(pad.(a0), h0), conv(pad.(a1), h1), &Cx.add/2)
        |> Enum.with_index()
        |> Enum.map(fn {y, n} ->
          {a, b} = y |> Cx.mul(Cx.expj(2 * :math.pi() * cfo * n)) |> Cx.scale(amp)
          {clamp(round(a + sigma * :rand.normal()) + 120), clamp(round(b + sigma * :rand.normal()) - 70)}
        end)
      end

    {m, p, t, ys}
  end

  defp clamp(v), do: v |> max(-2048) |> min(2047)

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
  @tag timeout: 1_800_000
  test "eig1 from samples: steered S1G PPDUs through 2x2 multipath + CFO -> RTL -> PSDU bytes" do
    cases = [{4, 80, 25.0, 0.0041, 21}, {7, 100, 31.0, -0.0067, 22}]
    frames = Enum.map(cases, &frame/1)
    # warm-up for the detector's DC tracker (1024 samples blanked)
    warm = List.duplicate({0, 0}, 1100)
    s0 = warm ++ Enum.flat_map(frames, fn {_, _, _, [y0, _]} -> y0 end)
    s1 = warm ++ Enum.flat_map(frames, fn {_, _, _, [_, y1]} -> y1 end)

    stim = Enum.zip_with(s0, s1, fn {a, b}, {c, d} -> "#{Cosim.hex(a, 12)} #{Cosim.hex(b, 12)} #{Cosim.hex(c, 12)} #{Cosim.hex(d, 12)}" end)
    header = "#{length(stim)} #{20 * 64}"
    lines = Cosim.run([MimoHalow.Hw.Rx.Eig1], "tb_rx_eig1.v", stim, header: header)

    {stats, rest} = Enum.split_with(lines, &String.starts_with?(&1, "S "))
    {syncs, rest} = Enum.split_with(rest, &String.starts_with?(&1, "D "))
    {sigs, rest} = Enum.split_with(rest, &String.starts_with?(&1, "G "))
    {bytes, outs} = Enum.split_with(rest, &String.starts_with?(&1, "B "))
    ["S " <> s] = stats
    [nsync, ndet, drop, ovr, vovf, early] = s |> String.split() |> Enum.map(&String.to_integer/1)
    assert {nsync, drop, ovr, vovf, early} == {length(cases), 0, 0, 0, 0}, "syncs #{inspect(syncs)}, dets #{ndet}"

    # The RTL's own PSDU bytes, split at b_last.
    rtl_psdus =
      bytes
      |> Enum.map(fn "B " <> b -> b |> String.split() |> Enum.map(&String.to_integer/1) end)
      |> Enum.chunk_while([], fn [v, l], acc -> if l == 1, do: {:cont, Enum.reverse([v | acc]), []}, else: {:cont, [v | acc]} end, fn acc -> {:cont, acc} end)
      |> Enum.map(&:binary.list_to_bin/1)

    assert rtl_psdus == Enum.map(frames, fn {_, p, _, _} -> p end)

    rows =
      Enum.map(outs, fn l ->
        [j, d, re, im, g, _th] = String.split(l)
        {String.to_integer(j), String.to_integer(d), Cosim.shex(re, 27), Cosim.shex(im, 27), String.to_integer(g)}
      end)

    # The RTL SIG decoder closed the feeder loop: one good SIG per PPDU, nsym = 4 + Ndata.
    assert Enum.map(sigs, fn "G " <> g -> g |> String.split() |> Enum.take(3) |> Enum.map(&String.to_integer/1) end) ==
             Enum.map(frames, fn {_, _, t, _} -> [1, 0, 4 + t.nsym] end)

    pks = packets(rows)
    assert length(pks) == length(cases)

    for {{m, p, t, _}, pts} <- Enum.zip(frames, pks) do
      assert length(pts) == 2 + t.nsym, "mcs #{m}: symbols out"
      assert {:ok, r} = Ppdu.decode_points(2, pts), "mcs #{m}"
      assert r.psdu == p, "mcs #{m}: PSDU"
      assert r.fcs_ok
    end
  end
end
