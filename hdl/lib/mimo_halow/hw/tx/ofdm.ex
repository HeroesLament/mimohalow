defmodule MimoHalow.Hw.Tx.Ofdm do
  @moduledoc """
  S1G 2 MHz short-preamble PPDU, frequency to time, transmit side: STF x 2 +
  LTF1 from ROM, then two SIG symbols and `nsym` data symbols through a
  64-point IFFT (`Hw.Fft64` as conj(FFT(conj X))) with a 16-sample cyclic
  prefix, at 2 MS/s with valid / ready. Twin of `Ppdu.tx/2`'s `samples` up to
  scale and FFT rounding.

  Inputs: `sig` (96 interleaved SIG coded bits, symbol 0 in [47:0], bit j on
  sig_data tone j, 1 -> +j), `mod` (0 BPSK .. 4 256-QAM), `nsym`, and the
  mapper's data points (`p_bin`, levels `p_i` / `p_q` in -15..15, `p_last` on
  point 51), held in a ping-pong buffer by bin.

  Scale: tones enter the FFT at 2^14 k_mod level (data), +-16384 (data
  pilots), +-17003 = 2^14 sqrt(56/52) (SIG tones and pilots: the SIG field's
  sqrt(1/52) normalisation against data's sqrt(1/56)). Output samples are
  (|S| * 3508) >> 16 per axis, which puts one unit of model time amplitude at
  6560 = 410 * 16, the 12-bit RMS 410 of `S1g.Air` with 4 fraction bits. The
  preamble ROM holds the model's first 320 samples at the same scale.

  Feed slot s (>= 256 cycles) sends frequency symbol s; slot 2 + nsym is a
  zero flush. The FFT returns time symbol s - 1 during slot s, written by
  `out_bin` (the time index) into one half of a ping-pong time buffer. The
  emitter sends the preamble, then each time symbol as n = 48..63, 0..63.
  `o_last` marks the final sample.
  """
  use Hw.Component

  alias MimoHalow.Model.S1g.{Coding, Params, Ppdu}

  @scale 6560
  @pre (Ppdu.tx(:binary.copy(<<0>>, 16), bw: 2, mcs: 0).samples
        |> Enum.take(320)
        |> Enum.map(fn {re, im} ->
          i = round(re * @scale) |> Bitwise.band(0xFFFF)
          q = round(im * @scale) |> Bitwise.band(0xFFFF)
          Bitwise.bor(Bitwise.bsl(i, 16), q)
        end))
  @pre_rom @pre ++ List.duplicate(0, 512 - 320)

  # Bin classes, address {is_sig, bin}: {cls(2), idx(6)}; cls 0 zero, 1 data,
  # 2 pilot (idx 0..3 for k = -21, -7, 7, 21), 3 SIG data tone (idx j).
  @cls (for sig? <- [0, 1], b <- 0..63 do
          k = if b < 32, do: b, else: b - 64
          pil = Enum.find_index(Params.pilots(2), &(&1 == k))
          dat = Enum.find_index(Params.data(2), &(&1 == k))
          sd = Enum.find_index(Params.sig_data(2), &(&1 == k))

          cond do
            pil != nil -> Bitwise.bor(Bitwise.bsl(2, 6), pil)
            sig? == 0 and dat != nil -> Bitwise.bsl(1, 6)
            sig? == 1 and sd != nil -> Bitwise.bor(Bitwise.bsl(3, 6), sd)
            true -> 0
          end
        end)

  # Pilot polarity: bit 1 where polarity(n) = -1.
  @pol (for n <- 0..127, do: if(n < 127 and Coding.polarity(n) == -1, do: 1, else: 0))

  clock(:clk, freq: 32.0)

  input(:start, 1)
  input(:mod, 3)
  input(:nsym, 10)
  input(:sig, 96)
  input(:p_valid, 1)
  input(:p_i, 5)
  input(:p_q, 5)
  input(:p_bin, 6)
  input(:p_last, 1)
  input(:o_ready, 1)

  output(:p_ready, 1)
  output(:o_valid, 1)
  output(:o_i, 16)
  output(:o_q, 16)
  output(:o_last, 1)
  output(:busy, 1)

  memory(:prom, width: 32, depth: 512, sync_read: :clk, init: @pre_rom)
  memory(:crom, width: 8, depth: 128, sync_read: :clk, init: @cls)
  memory(:prol, width: 1, depth: 128, sync_read: :clk, init: @pol)
  memory(:pbuf, width: 10, depth: 128, sync_read: :clk)
  memory(:tbuf, width: 32, depth: 128, sync_read: :clk)

  wire(:act, 1, init: 0)
  wire(:r_nsym, 10, init: 0)
  wire(:r_sig, 96, init: 0)
  wire(:kmod, 15, init: 0)

  # Point writer.
  wire(:phw, 1, init: 0)
  wire(:pf0, 1, init: 0)
  wire(:pf1, 1, init: 0)

  # Feed.
  wire(:fs, 2, init: 0)
  wire(:s, 11, init: 0)
  wire(:pol, 7, init: 0)
  wire(:fpos, 6, init: 0)
  wire(:c4, 2, init: 0)
  wire(:fft_en, 1, init: 0)
  wire(:fv, 1, init: 0)
  wire(:fi, 18, init: 0)
  wire(:fq, 18, init: 0)
  wire(:cls_q, 8, init: 0)
  wire(:pt_q, 10, init: 0)

  # FFT output collection.
  wire(:oh, 1, init: 0)
  wire(:ocnt, 6, init: 0)
  wire(:tf0, 1, init: 0)
  wire(:tf1, 1, init: 0)
  wire(:wv, 1, init: 0)
  wire(:wa, 7, init: 0)
  wire(:wd, 32, init: 0)
  wire(:p0v, 1, init: 0)
  wire(:p0h, 1, init: 0)
  wire(:p0d, 32, init: 0)

  # Emitter.
  wire(:es, 2, init: 0)
  wire(:eh, 1, init: 0)
  wire(:e, 11, init: 0)
  wire(:ec, 9, init: 0)
  wire(:tn, 6, init: 0)
  wire(:rv, 1, init: 0)
  wire(:rl, 1, init: 0)
  wire(:rsrc, 1, init: 0)
  wire(:ov, 1, init: 0)
  wire(:oi, 16, init: 0)
  wire(:oq, 16, init: 0)
  wire(:ol, 1, init: 0)

  # Combinational.
  wire(:zero12, 12)
  wire(:zero6, 6)
  wire(:yo_pos, 6)
  wire(:yo_tag, 12)
  wire(:yo_valid, 1)
  wire(:yo_bin, 6)
  wire(:yi, 26)
  wire(:yq, 26)
  wire(:nfreq, 11)
  wire(:is_sig, 1)
  wire(:is_flush, 1)
  wire(:dsym, 1)
  wire(:src_ok, 1)
  wire(:dst_ok, 1)
  wire(:pfree, 1)
  wire(:crq, 8)
  wire(:pbq, 10)
  wire(:polq, 1)
  wire(:cls, 2)
  wire(:idx, 6)
  wire(:li, 5)
  wire(:lq, 5)
  wire(:mi, 4)
  wire(:mq, 4)
  wire(:pi, 19)
  wire(:pq, 19)
  wire(:sig48, 48)
  wire(:sbit, 1)
  wire(:rot, 2)
  wire(:prot, 2)
  wire(:p3, 1)
  wire(:pneg, 1)
  wire(:pamp, 18)
  wire(:vi, 18)
  wire(:vq, 18)
  wire(:ai, 26)
  wire(:aq, 26)
  wire(:mpi, 38)
  wire(:mpq, 38)
  wire(:si, 22)
  wire(:sq, 22)
  wire(:ci, 16)
  wire(:cq, 16)
  wire(:wdi, 16)
  wire(:wdq, 16)
  wire(:tq, 32)
  wire(:prq, 32)
  wire(:can_issue, 1)
  wire(:tsel, 1)
  wire(:p0free, 1)

  instance :fft, Hw.Fft64,
    clk: :clk, enable: :fft_en, in_valid: :fv, in_i: :fi, in_q: :fq, in_tag: :zero12,
    out_valid: :yo_valid, out_i: :yi, out_q: :yq, out_pos: :yo_pos, out_bin: :yo_bin, out_tag: :yo_tag

  comb do
    zero12 = 0
    zero6 = 0
    nfreq = r_nsym + 2

    is_sig =
      if s < 2 do
        1
      else
        0
      end

    is_flush =
      if s == nfreq do
        1
      else
        0
      end

    # Data symbol m = s - 2 uses point half m & 1 = s & 1.
    dsym = s[0..0]

    src_ok =
      if is_sig == 1 or is_flush == 1 do
        1
      else
        if dsym == 0 do
          pf0
        else
          pf1
        end
      end

    # Slot s >= 1 writes time symbol s - 1 into half (s - 1) & 1.
    dst_ok =
      if s == 0 do
        1
      else
        if s[0..0] == 1 do
          ~~~tf0
        else
          ~~~tf1
        end
      end

    pfree =
      if phw == 0 do
        ~~~pf0
      else
        ~~~pf1
      end

    crq = crom[{is_sig, fpos}]
    pbq = pbuf[{dsym, fpos}]
    polq = prol[pol]

    cls = cls_q[7..6]
    idx = cls_q[5..0]
    li = pt_q[9..5]
    lq = pt_q[4..0]

    mi =
      if li[4..4] == 1 do
        0 - li
      else
        li
      end

    mq =
      if lq[4..4] == 1 do
        0 - lq
      else
        lq
      end

    pi = mi * kmod
    pq = mq * kmod

    sig48 =
      if s[0..0] == 0 do
        r_sig[47..0]
      else
        r_sig[95..48]
      end

    sbit = band(sig48 >>> idx, 1)

    # Data symbol m = s - 2: pattern [1 1 1 -1] rotated by m, so pilot i is
    # negative when (i + m) mod 4 == 3; SIG: unrotated, i == 3.
    rot = s[1..0] + 2
    prot = idx[1..0] + rot

    p3 =
      if is_sig == 1 do
        if idx == 3 do
          1
        else
          0
        end
      else
        if prot == 3 do
          1
        else
          0
        end
      end

    pneg = bxor(polq, p3)

    pamp =
      if is_sig == 1 do
        17003
      else
        16384
      end

    vi =
      case cls do
        1 ->
          if li[4..4] == 1 do
            0 - pi[17..0]
          else
            pi[17..0]
          end

        2 ->
          if pneg == 1 do
            0 - pamp
          else
            pamp
          end

        _ ->
          0
      end

    vq =
      case cls do
        1 ->
          if lq[4..4] == 1 do
            0 - pq[17..0]
          else
            pq[17..0]
          end

        3 ->
          if sbit == 1 do
            17003
          else
            0 - 17003
          end

        _ ->
          0
      end

    # Time sample = conj(FFT out): I = yi, Q = -yq; |x| * 3508 >> 16, clamped.
    ai =
      if yi[25..25] == 1 do
        0 - yi
      else
        yi
      end

    aq =
      if yq[25..25] == 1 do
        0 - yq
      else
        yq
      end

    mpi = ai * 3508
    mpq = aq * 3508
    si = mpi[37..16]
    sq = mpq[37..16]

    ci =
      if si > 32767 do
        32767
      else
        si[15..0]
      end

    cq =
      if sq > 32767 do
        32767
      else
        sq[15..0]
      end

    wdi =
      if yi[25..25] == 1 do
        0 - ci
      else
        ci
      end

    wdq =
      if yq[25..25] == 1 do
        cq
      else
        0 - cq
      end

    tq = tbuf[{eh, tn}]
    prq = prom[ec]

    can_issue =
      if ov == 0 and rv == 0 do
        1
      else
        0
      end

    tsel =
      if eh == 0 do
        tf0
      else
        tf1
      end

    p0free =
      if p0h == 0 do
        ~~~tf0
      else
        ~~~tf1
      end

    p_ready =
      if act == 1 and pfree == 1 do
        1
      else
        0
      end

    o_valid = ov
    o_i = oi
    o_q = oq
    o_last = ol
    busy = act
  end

  on :clk do
    if start == 1 do
      act = 1
      r_nsym = nsym
      r_sig = sig

      kmod =
        case mod do
          0 -> 16384
          1 -> 11585
          2 -> 5181
          3 -> 2528
          _ -> 1257
        end

      phw = 0
      pf0 = 0
      pf1 = 0
      fs = 0
      s = 0
      pol = 0
      fpos = 0
      c4 = 0
      fft_en = 0
      fv = 0
      oh = 0
      ocnt = 0
      p0v = 0
      tf0 = 0
      tf1 = 0
      wv = 0
      es = 0
      eh = 0
      e = 0
      ec = 0
      tn = 48
      rv = 0
      rl = 0
      ov = 0
      ol = 0
    else
      # --- data points in, by bin ---
      if p_ready == 1 and p_valid == 1 do
        pbuf[{phw, p_bin}] = {p_i, p_q}

        if p_last == 1 do
          if phw == 0 do
            pf0 = 1
          else
            pf1 = 1
          end

          phw = ~~~phw
        end
      end

      # --- feed: one FFT input every 4 cycles ---
      fv = 0

      case fs do
        0 ->
          if act == 1 and s <= nfreq and src_ok == 1 and dst_ok == 1 do
            fs = 1
            fpos = 0
            c4 = 0
            fft_en = 1
          end

        1 ->
          c4 = c4 + 1

          # c4 0: crom / pbuf addresses from fpos; 1: latch; 2: value; 3: send.
          if c4 == 1 do
            cls_q = crq
            pt_q = pbq
          end

          if c4 == 2 do
            if is_flush == 1 do
              fi = 0
              fq = 0
            else
              fi = vi
              fq = 0 - vq
            end
          end

          if c4 == 3 do
            fv = 1

            if fpos == 63 do
              fs = 2
            else
              fpos = fpos + 1
            end
          end

        2 ->
          # Slot done: release this data symbol's point half; next slot.
          if is_sig == 0 and is_flush == 0 do
            if dsym == 0 do
              pf0 = 0
            else
              pf1 = 0
            end
          end

          s = s + 1

          if pol == 126 do
            pol = 0
          else
            pol = pol + 1
          end

          fs = 0

        _ ->
          fs = 0
      end

      # --- FFT out -> time buffer by time index ---
      wv = 0

      # Symbol boundaries from the FFT's own out_pos. Position 0 of time symbol
      # k leaves at the end of feed slot k, before slot k + 1 has checked that
      # half k & 1 is emitted: hold it and commit once that half is free.
      # Positions 1..63 arrive in slot k + 1, which waits for the same.
      if p0v == 1 and yo_valid == 0 and p0free == 1 do
        wv = 1
        wa = {p0h, zero6}
        wd = p0d
        p0v = 0
      end

      if yo_valid == 1 and yo_pos == 0 do
        p0v = 1
        p0h = oh
        p0d = {wdi, wdq}
      end

      if yo_valid == 1 and yo_pos != 0 do
        wv = 1
        wa = {oh, yo_bin}
        wd = {wdi, wdq}

        if yo_pos == 63 do
          oh = ~~~oh

          if oh == 0 do
            tf0 = 1
          else
            tf1 = 1
          end
        end
      end

      if wv == 1 do
        tbuf[wa] = wd
      end

      # --- emitter: one read in flight, one output register ---
      if ov == 1 and o_ready == 1 do
        ov = 0
      end

      rv = 0
      rl = 0

      if rv == 1 do
        ov = 1
        ol = rl

        if rsrc == 0 do
          oi = prq[31..16]
          oq = prq[15..0]
        else
          oi = tq[31..16]
          oq = tq[15..0]
        end
      end

      case es do
        0 ->
          if act == 1 and can_issue == 1 do
            rv = 1
            rsrc = 0

            if ec == 319 do
              ec = 0
              es = 1
            else
              ec = ec + 1
            end
          end

        1 ->
          if tsel == 1 and can_issue == 1 do
            rv = 1
            rsrc = 1
            tn = tn + 1

            if ec == 79 do
              ec = 0
              tn = 48
              eh = ~~~eh
              e = e + 1

              if eh == 0 do
                tf0 = 0
              else
                tf1 = 0
              end

              if e + 1 == nfreq do
                rl = 1
                es = 2
              end
            else
              ec = ec + 1
            end
          end

        2 ->
          if ov == 0 and rv == 0 do
            act = 0
            es = 3
          end

        _ ->
          es = 3
      end
    end
  end
end
