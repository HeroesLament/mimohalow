defmodule MimoHalow.Model.S1g.Ppdu do
  @moduledoc """
  Float model of the 1-SS S1G PPDU: S1G_1M (1 MHz) and S1G_SHORT (2 MHz),
  BCC, MCS0-9 (+MCS10 at 1 MHz). `tx/2` builds the tone maps of every
  OFDM symbol and the time-domain samples at the base rate (1 or 2 Msps,
  no windowing); `rx/2` decodes a sample stream aligned to the packet start.

  Layout (samples at base rate, N = FFT size, GI = N/4):

      1 MHz: STF 4 x (GI + N) | LTF1 2GI + 2N + 2 x (GI + N) | SIG 6 x (GI + N) | data
      2 MHz: STF 2 x (GI + N) | LTF1 2GI + 2N                | SIG 2 x (GI + N) | data

  The 1 MHz LTF1 is the 2 MHz-style double symbol followed by two more
  repetitions with single GIs (Figure 23-3 of the draft).
  """
  import Bitwise
  alias MimoHalow.Model.{Bcc, Cx, Demap, Fft, Qam, Scrambler}
  alias MimoHalow.Model.S1g.{Coding, Params}

  @type opts :: [
          bw: 1 | 2,
          mcs: 0..10,
          scrambler: 1..127,
          aggregation: boolean,
          smoothing: 0 | 1,
          id: 0..511,
          uplink: 0 | 1,
          response: 0..3
        ]

  # --- SIG field ------------------------------------------------------------------

  @doc "SIG information bits (with CRC and tail): 36 at 1 MHz, 48 at 2 MHz."
  def sig_bits(1, f) do
    head =
      Coding.bits(0, 2) ++
        [0, 0, 1, 0, 1] ++
        Coding.bits(f.mcs, 4) ++
        [b(f.aggregation)] ++ Coding.bits(f.length, 9) ++ Coding.bits(f.response, 2) ++ [f.smoothing, 0, 0]

    head ++ Coding.crc4(head) ++ List.duplicate(0, 6)
  end

  def sig_bits(2, f) do
    head =
      [1, 0, f.uplink] ++
        Coding.bits(0, 2) ++
        Coding.bits(0, 2) ++
        Coding.bits(f.id, 9) ++
        [0, 0, 1] ++
        Coding.bits(f.mcs, 4) ++
        [f.smoothing, b(f.aggregation)] ++ Coding.bits(f.length, 9) ++ Coding.bits(f.response, 2) ++ [0, 0]

    head ++ Coding.crc4(head) ++ List.duplicate(0, 6)
  end

  @doc "Parse SIG information bits; `{:ok, fields}` or `{:error, :crc}`."
  def parse_sig(bw, bits) do
    n = if bw == 1, do: 26, else: 38
    {head, rest} = Enum.split(bits, n)

    if Enum.take(rest, 4) != Coding.crc4(head) do
      {:error, :crc}
    else
      f =
        case bw do
          1 ->
            %{nsts: v(head, 0, 2) + 1, sgi: at(head, 2), coding: at(head, 3), stbc: at(head, 5),
              mcs: v(head, 7, 4), aggregation: at(head, 11) == 1, length: v(head, 12, 9),
              response: v(head, 21, 2), smoothing: at(head, 23), ndp: at(head, 24), doppler: at(head, 25)}

          2 ->
            %{stbc: at(head, 1), uplink: at(head, 2), bw: v(head, 3, 2), nsts: v(head, 5, 2) + 1,
              id: v(head, 7, 9), sgi: at(head, 16), coding: at(head, 17), mcs: v(head, 19, 4),
              smoothing: at(head, 23), aggregation: at(head, 24) == 1, length: v(head, 25, 9),
              response: v(head, 34, 2), ndp: at(head, 36), doppler: at(head, 37)}
        end

      {:ok, f}
    end
  end

  defp at(l, i), do: Enum.at(l, i)
  defp v(l, i, n), do: l |> Enum.slice(i, n) |> Coding.value()
  defp b(true), do: 1
  defp b(false), do: 0

  # --- length / symbol count ---------------------------------------------------------

  @doc "Data symbol count for a PSDU of `len` bytes."
  def nsym(r, len), do: div(8 + 8 * len + 6 + r.ndbps - 1, r.ndbps)

  # --- TX -------------------------------------------------------------------------

  @doc """
  Build a PPDU carrying `psdu` (binary, FCS included). Returns
  `%{fields:, stf:, ltf:, sig: [tones], data: [tones], samples: [Cx]}`.
  """
  def tx(psdu, opts) do
    bw = Keyword.get(opts, :bw, 2)
    m = Keyword.get(opts, :mcs, 0)
    {:ok, r} = Params.rate(bw, m)
    len = byte_size(psdu)
    aggr = Keyword.get(opts, :aggregation, len >= 512)
    ns = nsym(r, len)

    f = %{
      mcs: m,
      aggregation: aggr,
      length: if(aggr, do: ns, else: len),
      smoothing: Keyword.get(opts, :smoothing, 1),
      id: Keyword.get(opts, :id, 0),
      uplink: Keyword.get(opts, :uplink, 1),
      response: Keyword.get(opts, :response, 0)
    }

    sig = sig_tones(bw, sig_bits(bw, f))
    data = data_tones(bw, r, psdu, ns, Keyword.get(opts, :scrambler, 0x5D))
    stf_boost = if m == 10, do: :math.sqrt(2), else: 1.0
    stf = Map.new(Params.stf(bw), fn {k, x} -> {k, Cx.scale(x, stf_boost)} end)
    ltf = Map.new(Params.ltf(bw), fn {k, s} -> {k, Cx.new(1.0 * s)} end)

    samples =
      List.duplicate(sym(bw, stf, :stf), if(bw == 1, do: 4, else: 2))
      |> Enum.concat()
      |> Kernel.++(ltf1(bw, ltf))
      |> Kernel.++(Enum.flat_map(sig, &sym(bw, &1, :sig)))
      |> Kernel.++(Enum.flat_map(data, &sym(bw, &1, :data)))

    %{fields: f, rate: r, nsym: ns, stf: stf, ltf: ltf, sig: sig, data: data, samples: samples}
  end

  defp ltf1(bw, ltf) do
    t = time(bw, ltf, :ltf)
    gi = Params.gi(bw)
    two = Enum.take(t, -2 * gi) ++ t ++ t
    if bw == 1, do: two ++ Enum.take(t, -gi) ++ t ++ Enum.take(t, -gi) ++ t, else: two
  end

  # GI + IFFT of one symbol.
  defp sym(bw, tones, field) do
    t = time(bw, tones, field)
    Enum.take(t, -Params.gi(bw)) ++ t
  end

  defp time(bw, tones, field) do
    n = Params.nfft(bw)
    g = Params.norm(field, bw) * n
    v = for i <- 0..(n - 1), do: Map.get(tones, if(i < div(n, 2), do: i, else: i - n), Cx.zero())
    v |> Fft.ifft() |> Enum.map(&Cx.scale(&1, g))
  end

  @doc "SIG OFDM symbols (tone maps) from the SIG information bits."
  def sig_tones(1, bits) do
    coded = Bcc.encode(bits)

    coded
    |> Enum.chunk_every(12)
    |> Enum.with_index()
    |> Enum.map(fn {c, n} ->
      x = c |> Coding.rep2() |> Coding.interleave(Params.interleaver(1, 1), 1)
      pts = Enum.map(x, &Cx.new(2.0 * &1 - 1))
      Map.merge(Map.new(Enum.zip(Params.data(1), pts)), cx(Coding.pilot_values(1, n, n)))
    end)
  end

  def sig_tones(2, bits) do
    bits
    |> Bcc.encode()
    |> Enum.chunk_every(48)
    |> Enum.with_index()
    |> Enum.map(fn {c, n} ->
      x = Coding.interleave(c, Params.interleaver(:sig2, 1), 1)
      # QBPSK on both 2 MHz short SIG symbols
      pts = Enum.map(x, &Cx.new(0.0, 2.0 * &1 - 1))
      Map.merge(Map.new(Enum.zip(Params.sig_data(2), pts)), cx(Coding.pilot_values(2, 0, n, false)))
    end)
  end

  defp cx(m), do: Map.new(m, fn {k, p} -> {k, Cx.new(1.0 * p)} end)

  @doc "Data OFDM symbols: SERVICE(8) | PSDU | pad | tail(6), scrambled, BCC, punctured."
  def data_tones(bw, r, psdu, ns, scr) do
    nbits = ns * r.ndbps
    payload = [0 | Coding.bits(0, 7)] ++ Coding.bytes_to_bits(psdu)
    pad = nbits - length(payload) - 6
    {seq, _} = Scrambler.sequence(nbits, scr)
    scr_bits = Enum.zip_with(payload ++ List.duplicate(0, pad + 6), seq, &bxor/2)
    scr_bits = Enum.take(scr_bits, nbits - 6) ++ List.duplicate(0, 6)
    coded = scr_bits |> Bcc.encode() |> Coding.puncture(r.rate)
    z = Params.sig_syms(bw)

    coded
    |> Enum.chunk_every(r.ncbps)
    |> Enum.with_index()
    |> Enum.map(fn {c, m} ->
      c = if r.rep, do: Coding.rep2(c), else: c
      x = Coding.interleave(c, Params.interleaver(bw, r.nbpsc), r.nbpsc)
      pts = Qam.map(x, r.mod)
      Map.merge(Map.new(Enum.zip(Params.data(bw), pts)), cx(Coding.pilot_values(bw, m, m + z)))
    end)
  end

  # --- RX -------------------------------------------------------------------------

  @doc """
  Decode a sample list aligned so sample 0 is the first STF sample (base
  rate, no CFO). Returns `{:ok, %{fields:, psdu:, fcs_ok:}}` or an error.
  """
  def rx(samples, bw) do
    do_rx(samples, bw)
  catch
    {:rx, err} -> err
  end

  defp do_rx(samples, bw) do
    n = Params.nfft(bw)
    gi = Params.gi(bw)
    nstf = if bw == 1, do: 4, else: 2
    t = List.to_tuple(samples)
    l0 = nstf * (gi + n) + 2 * gi
    # 2 MHz: two LTF repetitions; 1 MHz: four (the last two after single GIs).
    reps = [l0, l0 + n] ++ if(bw == 1, do: [l0 + 2 * n + gi, l0 + 3 * n + 2 * gi], else: [])
    h = estimate(bw, Enum.map(reps, &fft_at(t, &1, n)))
    s0 = l0 + 2 * n + if(bw == 1, do: 2 * (gi + n), else: 0)
    nsig = Params.sig_syms(bw)
    sigs = for i <- 0..(nsig - 1), do: fft_at(t, s0 + i * (gi + n) + gi, n)

    with {:ok, f} <- decode_sig(bw, h, sigs),
         {:ok, r} <- Params.rate(bw, f.mcs) do
      ns = if f.aggregation, do: f.length, else: nsym(r, f.length)
      d0 = s0 + nsig * (gi + n)

      if ns < 1 or d0 + ns * (gi + n) > tuple_size(t) do
        throw({:rx, {:error, {:truncated, ns}}})
      end

      ys = for m <- 0..(ns - 1), do: fft_at(t, d0 + m * (gi + n) + gi, n)
      {:ok, finish(f, r, ns, decode_data(bw, r, h, ys))}
    end
  end

  def fcs_ok?(psdu) when byte_size(psdu) < 4, do: false

  def fcs_ok?(psdu) do
    bits = Coding.bytes_to_bits(psdu)
    {x, fcs} = Enum.split(bits, length(bits) - 32)
    Coding.fcs(x) == fcs
  end

  defp fft_at(t, at, n) do
    xs = for i <- 0..(n - 1), do: elem(t, at + i)
    ys = Fft.fft(xs)
    Map.new(Enum.with_index(ys), fn {y, i} -> {if(i < div(n, 2), do: i, else: i - n), y} end)
  end

  defp estimate(bw, ltfs) do
    g = Params.norm(:ltf, bw) * Params.nfft(bw)

    Map.new(Params.ltf(bw), fn {k, s} ->
      y = ltfs |> Enum.map(& &1[k]) |> Cx.sum() |> Cx.scale(1.0 / length(ltfs))
      {k, Cx.scale(y, s / g)}
    end)
  end

  # Equalise one symbol on `tones` with pilot common-phase correction.
  defp equalise(bw, h, y, field, pilots, tones) do
    g = Params.norm(field, bw) * Params.nfft(bw)
    eq = fn k -> Cx.scale(Cx.div(y[k], h[k]), 1.0 / g) end

    cpe =
      pilots
      |> Enum.map(fn {k, p} -> Cx.scale(eq.(k), p) end)
      |> Cx.sum()

    rot = Cx.conj(Cx.scale(cpe, 1.0 / :math.sqrt(Cx.abs2(cpe))))

    Enum.map(tones, fn k ->
      hk = h[k]
      {Cx.mul(eq.(k), rot), 1.0 / (Cx.abs2(hk) * g * g)}
    end)
  end

  defp decode_sig(bw, h, sigs) do
    sigs
    |> Enum.with_index()
    |> Enum.map(fn {y, n} ->
      pil = if bw == 1, do: Coding.pilot_values(1, n, n), else: Coding.pilot_values(2, 0, n, false)
      equalise(bw, h, y, :sig, pil, Params.sig_data(bw))
    end)
    |> sig_from_points(bw)
  end

  defp decode_data(bw, r, h, ys) do
    z = Params.sig_syms(bw)

    ys
    |> Enum.with_index()
    |> Enum.map(fn {y, m} -> equalise(bw, h, y, :data, Coding.pilot_values(bw, m, m + z), Params.data(bw)) end)
    |> data_from_points(bw, r)
  end

  @doc """
  SIG from equalised points: one list per SIG symbol of `{x, nvar}` on
  `Params.sig_data(bw)` tones, in tone order.
  """
  def sig_from_points(syms, bw) do
    llrs =
      Enum.flat_map(syms, fn pts ->
        # BPSK (1 MHz) / QBPSK (2 MHz): bit 1 -> +1 on the used axis. LLR = log P0/P1.
        l = Enum.map(pts, fn {{re, im}, nv} -> -4.0 * if(bw == 1, do: re, else: im) / nv end)

        case bw do
          1 -> l |> Coding.deinterleave(Params.interleaver(1, 1), 1) |> Coding.unrep2()
          2 -> Coding.deinterleave(l, Params.interleaver(:sig2, 1), 1)
        end
      end)

    parse_sig(bw, Bcc.viterbi(llrs, terminated: true))
  end

  @doc "Descrambled DATA bits from equalised points (one `{x, nvar}` list per symbol, data tones)."
  def data_from_points(syms, bw, r) do
    llrs =
      Enum.flat_map(syms, fn pts ->
        l = Enum.flat_map(pts, fn {x, nv} -> Demap.llrs(x, max(nv, 1.0e-6), r.mod) end)
        l = Coding.deinterleave(l, Params.interleaver(bw, r.nbpsc), r.nbpsc)
        if r.rep, do: Coding.unrep2(l), else: l
      end)

    # one rate-1/2 output pair per information bit
    coded = Coding.depuncture(llrs, r.rate, length(syms) * r.ndbps)
    descramble(Bcc.viterbi(coded, terminated: true))
  end

  @doc """
  Back end on per-symbol equalised data-tone points (symbol 0 = first SIG
  symbol; each a list of `{x, nvar}` in `Params.data(bw)` order, as the RTL
  detector + CPE emit them). Returns what `rx/2` returns.
  """
  def decode_points(bw, syms) do
    nsig = Params.sig_syms(bw)
    {sig_syms, data_syms} = Enum.split(syms, nsig)
    pos = Params.data(bw) |> Enum.with_index() |> Map.new()
    sel = Enum.map(Params.sig_data(bw), &pos[&1])
    sig_pts = Enum.map(sig_syms, fn pts -> t = List.to_tuple(pts); Enum.map(sel, &elem(t, &1)) end)

    with {:ok, f} <- sig_from_points(sig_pts, bw),
         {:ok, r} <- Params.rate(bw, f.mcs) do
      ns = if f.aggregation, do: f.length, else: nsym(r, f.length)

      if ns > length(data_syms) do
        {:error, {:truncated, ns}}
      else
        bits = data_from_points(Enum.take(data_syms, ns), bw, r)
        {:ok, finish(f, r, ns, bits)}
      end
    end
  end

  defp finish(f, r, ns, bits) do
    payload = Enum.drop(bits, 8)
    len = if f.aggregation, do: div(length(payload) - 6, 8), else: f.length
    psdu = payload |> Enum.take(8 * len) |> Coding.bits_to_bytes()
    %{fields: f, rate: r, nsym: ns, psdu: psdu, fcs_ok: fcs_ok?(psdu)}
  end

  # Seed from the first 7 (zero) SERVICE bits: the scrambler output there is the seed's sequence.
  defp descramble(bits) do
    first7 = Enum.take(bits, 7)
    seed = Enum.find(1..127, fn s -> elem(Scrambler.sequence(7, s), 0) == first7 end) || 1
    Scrambler.scramble(bits, seed)
  end
end
