defmodule MimoHalow.Hw.PhyHostTest do
  @moduledoc """
  The board-facing receive PHY end to end: two-chain 8 MS/s samples (S1G 2
  MHz PPDUs steered per tone through a 2x2 channel, CFO, DC, noise, and an
  equal-power interferer in the adjacent channel at +2 MHz) -> PhyHost
  (Decim4 -> Rx.Eig1 -> receive ring) -> the ring read back through the AXI
  memory window -> PSDUs.
  """
  use ExUnit.Case
  import Bitwise
  alias MimoHalow.Model.{Cx, Fft, Mat2}
  alias MimoHalow.Model.S1g.{Coding, Params, Ppdu}
  alias MimoHalow.Test.Cosim

  @n 256
  @gi 64

  defp psdu(n, seed) do
    :rand.seed(:exsss, {seed, 1, 1})
    body = for _ <- 1..n, into: <<>>, do: <<:rand.uniform(256) - 1>>
    body <> Coding.bits_to_bytes(Coding.fcs(Coding.bytes_to_bits(body)))
  end

  defp time(tones, g) do
    v = for i <- 0..(@n - 1), do: Map.get(tones, if(i < div(@n, 2), do: i, else: i - @n), Cx.zero())
    v |> Fft.ifft() |> Enum.map(&Cx.scale(&1, g * @n))
  end

  defp cp(t, l), do: Enum.take(t, -l) ++ t

  # Per-tone 2x2 channel from 3 taps at 2 MS/s spacing (k on the 64-point grid).
  defp channel(seed) do
    :rand.seed(:exsss, {seed, 4, 4})
    pw = [1.0, 0.35, 0.12]
    taps = for _r <- 0..1, do: (for _t <- 0..1, do: Enum.map(pw, fn p -> s = :math.sqrt(p / 2 / 1.47); {s * :rand.normal(), s * :rand.normal()} end))

    Map.new(Params.used(2), fn k ->
      h = for row <- taps, do: (for tl <- row, do: tl |> Enum.with_index() |> Enum.map(fn {h, l} -> Cx.mul(h, Cx.expj(-2 * :math.pi() * k * l / 64)) end) |> Cx.sum())
      [[a, b], [c, d]] = h
      {k, {{a, b}, {c, d}}}
    end)
  end

  # Received 8 MS/s baseband per chain for one steered PPDU, plus the interferer.
  defp frame({m, len, snr, cfo, seed}) do
    p = psdu(len, seed)
    t = Ppdu.tx(p, bw: 2, mcs: m, smoothing: 0, scrambler: 1 + rem(seed * 11, 127))
    hs = channel(seed)
    vs = Map.new(hs, fn {k, h} -> {_, _, v} = Mat2.svd(h); {k, Mat2.col(v, 0)} end)
    :rand.seed(:exsss, {seed, 9, 9})
    aci_k = if System.get_env("MH_NOACI"), do: [], else: Enum.to_list(36..92)
    aci = fn -> Map.new(aci_k, fn k -> {k, {Enum.random([-0.7, 0.7]), Enum.random([-0.7, 0.7])}} end) end

    rx_sym = fn tones, field ->
      g = Params.norm(field, 2)
      for r <- 0..1 do
        y =
          Map.new(tones, fn {k, x} ->
            {{h00, h01}, {h10, h11}} = hs[k]
            {v0, v1} = vs[k]
            {hr0, hr1} = if r == 0, do: {h00, h01}, else: {h10, h11}
            {k, Cx.mul(x, Cx.add(Cx.mul(hr0, v0), Cx.mul(hr1, v1)))}
          end)
          |> Map.merge(Map.new(aci.(), fn {k, x} -> {k, Cx.scale(x, 1.0 / g * :math.sqrt(1 / 56))} end))

        time(y, g)
      end
    end

    two = fn [a, b], f -> [f.(a), f.(b)] end
    stf = rx_sym.(t.stf, :stf) |> two.(&cp(&1, @gi))
    ltf = rx_sym.(t.ltf, :ltf) |> two.(&cp(&1 ++ &1, 2 * @gi))
    sigs = Enum.map(t.sig, &(rx_sym.(&1, :sig) |> two.(fn x -> cp(x, @gi) end)))
    data = Enum.map(t.data, &(rx_sym.(&1, :data) |> two.(fn x -> cp(x, @gi) end)))

    chain = fn r ->
      Enum.at(stf, r) ++ Enum.at(stf, r) ++ Enum.at(ltf, r) ++ Enum.flat_map(sigs, &Enum.at(&1, r)) ++ Enum.flat_map(data, &Enum.at(&1, r))
    end

    amp = 500.0
    sigma = amp * :math.pow(10, -snr / 20) / :math.sqrt(2)
    pad = fn xs -> List.duplicate(Cx.zero(), 1200) ++ xs ++ List.duplicate(Cx.zero(), 1600) end

    ys =
      for r <- 0..1 do
        chain.(r)
        |> pad.()
        |> Enum.with_index()
        |> Enum.map(fn {y, n} ->
          {a, b} = y |> Cx.mul(Cx.expj(2 * :math.pi() * cfo * n)) |> Cx.scale(amp)
          {clamp(round(a + sigma * :rand.normal()) + 90), clamp(round(b + sigma * :rand.normal()) - 60)}
        end)
      end

    {p, t, ys}
  end

  defp clamp(v), do: v |> max(-2048) |> min(2047)

  defp psdus(entries) do
    entries
    |> Enum.reject(fn e -> (e >>> 31) == 0 end)
    |> Enum.flat_map(fn e ->
      n = e >>> 28 &&& 3
      for i <- 0..(n - 1), do: {e >>> (8 * i) &&& 0xFF, if(i == n - 1, do: e >>> 30 &&& 1, else: 0)}
    end)
    |> Enum.chunk_while([], fn {b, l}, acc -> if l == 1, do: {:cont, Enum.reverse([b | acc]), []}, else: {:cont, [b | acc]} end, fn acc -> {:cont, acc} end)
    |> Enum.map(&:binary.list_to_bin/1)
  end

  @tag :iverilog
  @tag timeout: 3_600_000
  test "PhyHost: 8 MS/s two-chain samples with adjacent-channel interference -> ring -> PSDUs" do
    # cfo in cycles per 8 MS/s sample (0.0012 = 9.6 kHz)
    cases = [{4, 70, 26.0, 0.0012, 31}, {7, 90, 32.0, -0.0009, 32}]
    frames = Enum.map(cases, &frame/1)
    warm = List.duplicate({0, 0}, 4400)
    s0 = warm ++ Enum.flat_map(frames, fn {_, _, [y0, _]} -> y0 end)
    s1 = warm ++ Enum.flat_map(frames, fn {_, _, [_, y1]} -> y1 end)
    stim = Enum.zip_with(s0, s1, fn {a, b}, {c, d} -> Enum.map_join([a, b, c, d], " ", &Cosim.hex(&1, 12)) end)
    # phy_en, emin code 2 (1024)
    ctl = 1 <<< 5 ||| 2 <<< 26
    lines = Cosim.run([MimoHalow.Hw.PhyHost], "tb_phy_host.v", stim, header: "#{length(stim)} #{Integer.to_string(ctl, 16)}")

    ["W " <> w | rest] = lines
    {["M " <> m], rs} = Enum.split_with(rest, &String.starts_with?(&1, "M "))
    entries = Enum.map(rs, fn "R " <> e -> String.to_integer(e, 16) end)
    assert length(entries) == String.to_integer(w)
    [mon0, mon1, mon2] = m |> String.split() |> Enum.map(&String.to_integer(&1, 16))
    sigs = for e <- entries, (e >>> 28) == 1, do: {e >>> 27 &&& 1, e >>> 26 &&& 1, e >>> 22 &&& 15}
    diag = "sync #{mon0 >>> 16} drop #{mon0 &&& 0xFFFF} det #{mon1 >>> 16} flags #{mon1 &&& 7} preempt #{mon2 >>> 16} sigs #{inspect(sigs)}"

    # The stimulus starts from digital zero, and the detector fires on the
    # step to noise + DC ~300 samples (2 MS/s) before the first PPDU: that
    # phantom packet must be preempted, not cost the real one.
    assert (mon0 &&& 0xFFFF) == 0, diag
    assert (mon2 >>> 16) >= 1, diag
    assert (mon1 &&& 3) == 0, diag
    assert Enum.filter(sigs, fn {_, discard, _} -> discard == 0 end) == Enum.map(frames, fn {_, t, _} -> {1, 0, t.fields.mcs} end), diag
    assert psdus(entries) == Enum.map(frames, fn {p, _, _} -> p end), diag
  end
end
