defmodule MimoHalow.Model.Sounder do
  @moduledoc """
  2x2 channel sounder for the f63 DMA instrument (8 MS/s, cyclic 131072-frame
  TX ring, both chains captured raw by `Nervezynq.HPStream`).

  Period, #{2048} samples (256 us), 64 per ring:

      sync  320  half-repeating symbol on TX1 (even tones only): timing, CFO
      t1a   320  sounding symbol X on TX1, TX2 silent
      t1b   320  X again on TX1 (noise and fine CFO from the difference)
      t2a   320  X on TX2, TX1 silent
      t2b   320  X again on TX2
      guard 448  silence

  Symbols are 256-point OFDM with a 64-sample CP: 31.25 kHz tones (the S1G
  spacing), tones -100..100 less DC occupied (6.25 MHz). The receiver LS
  estimate per tone is `H[r][t] = mean(Y_r(t*a), Y_r(t*b)) / X`.

  Ring word (64 bit, the `TxLoop` format): [11:0] I1, [23:12] Q1, [35:24] I2,
  [47:36] Q2, 12-bit two's complement. Capture word (`HPStream.decode_word`):
  the same I/Q layout, [61:48] SEQ.
  """
  import Bitwise
  alias MimoHalow.Model.{Cx, Fft, Mat2}
  alias MimoHalow.Model.Mimo.Channel

  @nfft 256
  @cp 64
  @sym @nfft + @cp
  @period 2048
  @ring 131_072
  @half div(@nfft, 2)
  @tones Enum.to_list(-100..-1) ++ Enum.to_list(1..100)
  @offsets %{sync: 0, t1a: 320, t1b: 640, t2a: 960, t2b: 1280}
  @rms 400.0

  def period, do: @period
  def tones, do: @tones
  def offsets, do: @offsets

  @doc "Frequency-domain sounding symbol: `%{tone => Cx}`, QPSK, fixed seed."
  def x_freq, do: qpsk_tones(@tones, 0x50D)

  def sync_freq, do: qpsk_tones(Enum.filter(@tones, &(rem(abs(&1), 2) == 0)), 0x5C)

  defp qpsk_tones(tones, seed) do
    {pts, _} =
      Enum.map_reduce(tones, Channel.rng(seed), fn k, r ->
        {a, r} = :rand.uniform_s(4, r)
        {{k, Cx.expj(:math.pi() / 4 + (a - 1) * :math.pi() / 2)}, r}
      end)

    Map.new(pts)
  end

  @doc "Time-domain symbol with CP, `@sym` samples, scaled to `@rms`."
  def symbol(freq) do
    bins = for b <- 0..(@nfft - 1), do: Map.get(freq, if(b < @half, do: b, else: b - @nfft), Cx.zero())
    body = Fft.ifft(bins)
    p = Enum.sum(Enum.map(body, &Cx.abs2/1)) / @nfft
    body = Enum.map(body, &Cx.scale(&1, @rms / :math.sqrt(p)))
    Enum.take(body, -@cp) ++ body
  end

  @doc "One period as `[{tx1, tx2}]` complex samples."
  def period_samples do
    s = symbol(sync_freq())
    x = symbol(x_freq())
    z = List.duplicate(Cx.zero(), @sym)
    tx1 = s ++ x ++ x ++ z ++ z ++ List.duplicate(Cx.zero(), @period - 5 * @sym)
    tx2 = z ++ z ++ z ++ x ++ x ++ List.duplicate(Cx.zero(), @period - 5 * @sym)
    Enum.zip(tx1, tx2)
  end

  @doc "1 MB little-endian ring image (131072 words)."
  def ring_image do
    one = period_samples() |> Enum.map(&word/1) |> IO.iodata_to_binary()
    :binary.copy(one, div(@ring, @period))
  end

  defp word({{i1, q1}, {i2, q2}}) do
    w = q12(i1) ||| q12(q1) <<< 12 ||| q12(i2) <<< 24 ||| q12(q2) <<< 36
    <<w::little-unsigned-64>>
  end

  defp q12(v), do: v |> round() |> max(-2047) |> min(2047) |> band(0xFFF)

  @doc "Capture words (u64) -> `{ch1, ch2}` complex sample tuples."
  def decode_capture(u64s) do
    s = fn v -> if v >= 2048, do: v - 4096, else: v end

    {a, b} =
      u64s
      |> Enum.map(fn w ->
        {Cx.new(s.(w &&& 0xFFF), s.(w >>> 12 &&& 0xFFF)), Cx.new(s.(w >>> 24 &&& 0xFFF), s.(w >>> 36 &&& 0xFFF))}
      end)
      |> Enum.unzip()

    {List.to_tuple(a), List.to_tuple(b)}
  end

  @doc """
  Analyse a capture `{ch1, ch2}` (tuples of `Cx`). Returns
  `%{cfo_hz: f, periods: [%{start: n, h: %{tone => 2x2}, noise: [[v]]}]}`
  where `h` rows are RX chains and columns TX chains, and `noise` the
  per-entry noise variance of the estimate (same units as `|H|^2`).
  """
  def analyse(cap, opts \\ []) do
    fs = Keyword.get(opts, :fs, 8.0e6)
    {c1, c2} = cap = remove_dc(cap)
    n = tuple_size(c1)
    t0 = coarse_start(cap, n)
    starts = if t0 + @period <= n, do: Enum.to_list(t0..(n - @period)//@period), else: []
    starts = Enum.map(starts, &(refine(cap, &1 + 4, n) ))

    cfo =
      starts
      |> Enum.map(&sync_autocorr(cap, &1))
      |> Cx.sum()
      |> then(fn {a, b} -> :math.atan2(b, a) / (2 * :math.pi() * @half) end)

    fine =
      starts
      |> Enum.map(fn st -> rep_corr(cap, st, cfo) end)
      |> Cx.sum()
      |> then(fn {a, b} -> :math.atan2(b, a) / (2 * :math.pi() * @sym) end)

    cfo = cfo + fine
    x = x_freq()

    periods =
      for st <- starts do
        ys =
          for {name, off} <- Map.delete(@offsets, :sync), into: %{} do
            {name, {fft_at(c1, st + off + @cp, cfo), fft_at(c2, st + off + @cp, cfo)}}
          end

        est = fn rx, a, b ->
          for k <- @tones, into: %{} do
            ya = Map.fetch!(elem(ys[a], rx), k)
            yb = Map.fetch!(elem(ys[b], rx), k)
            xk = Map.fetch!(x, k)
            {k, {Cx.div(Cx.scale(Cx.add(ya, yb), 0.5), xk), Cx.abs2(Cx.div(Cx.sub(ya, yb), xk)) / 4}}
          end
        end

        e = for rx <- 0..1, {a, b} <- [{:t1a, :t1b}, {:t2a, :t2b}], into: %{}, do: {{rx, a}, est.(rx, a, b)}

        h =
          for k <- @tones, into: %{} do
            g = fn rx, a -> elem(Map.fetch!(e[{rx, a}], k), 0) end
            {k, {{g.(0, :t1a), g.(0, :t2a)}, {g.(1, :t1a), g.(1, :t2a)}}}
          end

        noise =
          for rx <- 0..1 do
            for a <- [:t1a, :t2a], do: mean(for k <- @tones, do: elem(Map.fetch!(e[{rx, a}], k), 1))
          end

        %{start: st, h: h, noise: noise}
      end

    %{cfo_hz: cfo * fs, cfo_cyc: cfo, periods: periods}
  end

  @doc """
  Per-entry power and SNR (dB) as medians over the clean periods. A period
  is rejected (interference burst) when its mean SNR is more than 6 dB below
  the capture median. `eig_spread_db` is the median over tones and clean
  periods of s1^2 / s2^2.
  """
  def summary(%{periods: ps} = a) do
    stats = Enum.map(ps, &period_stats/1)
    med = median(Enum.map(stats, &mean(List.flatten(&1.snr))))
    good = for {p, st} <- Enum.zip(ps, stats), mean(List.flatten(st.snr)) >= med - 6.0, do: {p, st}
    gs = Enum.map(good, &elem(&1, 1))

    pick = fn key ->
      for rx <- 0..1 do
        for tx <- 0..1, do: median(for st <- gs, do: st[key] |> Enum.at(rx) |> Enum.at(tx))
      end
    end

    spread =
      median(
        for {p, _} <- good, {_k, h} <- p.h do
          {_, {s1, s2}, _} = Mat2.svd(h)
          db(s1 * s1 / max(s2 * s2, 1.0e-30))
        end
      )

    %{
      cfo_hz: a.cfo_hz,
      periods: length(ps),
      rejected: length(ps) - length(good),
      power_db: pick.(:power),
      snr_db: pick.(:snr),
      eig_spread_db: spread
    }
  end

  defp period_stats(p) do
    power =
      for rx <- 0..1 do
        for tx <- 0..1, do: mean(for {_k, h} <- p.h, do: Cx.abs2(entry(h, rx, tx)))
      end

    snr =
      for {pr, nr} <- Enum.zip(power, p.noise) do
        for {pw, v} <- Enum.zip(pr, nr), do: db(pw / max(v, 1.0e-30))
      end

    %{power: Enum.map(power, fn r -> Enum.map(r, &db/1) end), snr: snr}
  end

  defp median([]), do: 0.0
  defp median(xs), do: xs |> Enum.sort() |> Enum.at(div(length(xs), 2))

  def entry({{a, b}, {c, d}}, rx, tx), do: elem(elem({{a, b}, {c, d}}, rx), tx)

  # Coarse: Schmidl-Cox on both chains (a CP-wide plateau); fine: cross-
  # correlation with the known sync body. Returns the period start, backed
  # off 4 samples into the CP.
  defp coarse_start(cap, n) do
    span = min(n - 2 * @period, @period)
    best = Enum.max_by(0..(span - 1)//4, fn d -> sc_metric(cap, d + @cp) end)
    refine(cap, best, n, 80)
  end

  defp refine(cap, st, n, w \\ 8) do
    lo = max(st - w, 0)
    hi = min(st + w, n - @period)
    Enum.max_by(lo..hi, &xcorr(cap, &1 + @cp)) |> Kernel.-(4) |> max(0)
  end

  defp sync_body do
    case :persistent_term.get({__MODULE__, :sync_body}, nil) do
      nil ->
        b = sync_freq() |> symbol() |> Enum.drop(@cp) |> Enum.map(&Cx.conj/1) |> List.to_tuple()
        :persistent_term.put({__MODULE__, :sync_body}, b)
        b

      b ->
        b
    end
  end

  # Cross-correlation with the known sync body, combined non-coherently over
  # 32-sample sub-blocks so a CFO of tens of kHz does not smear the peak.
  defp xcorr({c1, c2}, d) do
    b = sync_body()

    Enum.sum(
      for c <- [c1, c2], blk <- 0..7 do
        Cx.abs2(Cx.sum(for m <- (blk * 32)..(blk * 32 + 31), do: Cx.mul(elem(b, m), elem(c, d + m))))
      end
    )
  end

  @doc "Timing diagnostics over one period from `from`: `[{d, sc_metric, xcorr}]` every `step`."
  def timing_profile(cap, from \\ 0, step \\ 16) do
    cap = remove_dc(cap)
    for d <- from..(from + @period - 1)//step, do: {d, sc_metric(cap, d + @cp), xcorr(cap, d + @cp)}
  end

  # |P|^2 / (E1 E2): bounded by 1 (Cauchy-Schwarz), so signal/silence edges
  # cannot outscore the sync plateau.
  defp sc_metric(cap, d) do
    p = sync_autocorr_at(cap, d)
    e1 = energy(cap, d, @half)
    e2 = energy(cap, d + @half, @half)
    Cx.abs2(p) / max(e1 * e2, 1.0e-9)
  end

  defp sync_autocorr(cap, st), do: sync_autocorr_at(cap, st + 4 + @cp)

  defp sync_autocorr_at({c1, c2}, d) do
    Cx.sum(
      for c <- [c1, c2], m <- 0..(@half - 1) do
        Cx.mul(Cx.conj(elem(c, d + m)), elem(c, d + m + @half))
      end
    )
  end

  defp rep_corr({c1, c2}, st, cfo) do
    rot = Cx.expj(-2 * :math.pi() * cfo * @sym)

    Cx.sum(
      for c <- [c1, c2], {a, _b} <- [{@offsets.t1a, @offsets.t1b}, {@offsets.t2a, @offsets.t2b}],
          m <- 0..(@nfft - 1) do
        i = st + a + @cp + m
        Cx.mul(Cx.mul(Cx.conj(elem(c, i)), elem(c, i + @sym)), rot)
      end
    )
  end

  defp energy({c1, c2}, d, len) do
    Enum.sum(for c <- [c1, c2], m <- 0..(len - 1), do: Cx.abs2(elem(c, d + m)))
  end

  # Transmit scale of a unit-magnitude symbol with `ntones` tones.
  defp tx_scale(ntones), do: @rms * @nfft / :math.sqrt(ntones)

  defp fft_at(c, start, cfo) do
    xs = for m <- 0..(@nfft - 1), do: Cx.mul(elem(c, start + m), Cx.expj(-2 * :math.pi() * cfo * (start + m)))
    bins = Fft.fft(xs) |> List.to_tuple()
    k_s = 1 / tx_scale(length(@tones))
    for k <- @tones, into: %{}, do: {k, Cx.scale(elem(bins, if(k < 0, do: k + @nfft, else: k)), k_s)}
  end

  @doc "Subtract each chain's mean (the AD9363 RX DC offset dominates raw captures)."
  def remove_dc({c1, c2}), do: {dc_free(c1), dc_free(c2)}

  defp dc_free(c) do
    l = Tuple.to_list(c)
    m = Cx.scale(Cx.sum(l), 1 / length(l))
    l |> Enum.map(&Cx.sub(&1, m)) |> List.to_tuple()
  end

  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)
  defp db(x), do: 10 * :math.log10(max(x, 1.0e-30))
end
