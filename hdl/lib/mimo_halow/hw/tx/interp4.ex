defmodule MimoHalow.Hw.Tx.HbUp do
  @moduledoc """
  Generator for the x2 half-band interpolators of `MimoHalow.Hw.Tx.Interp4`:
  `HbUp2` (Decim4.h2, 59 taps, Q17) and `HbUp1` (Decim4.h1, 15 taps, Q15),
  the polyphase form of `S1g.Air.up2/3`. Per input x[m]: an even output
  y[2m] = 2 sum_j g[j] x[m - j] / 2^q over the N side taps g[j] = h[2j], then
  an odd output y[2m + 1] = x[m - d] (centre tap at gain 2 is 1), d = (c - 1)
  / 2. After the input flagged `i_last` the stage feeds (taps - 1) / 2 zero
  inputs, so it emits 2n + taps - 1 outputs like the model; `o_last` marks
  the final one.

  Serial MAC with symmetric pre-add (g[j] = g[N - 1 - j]), two lanes per rail
  (j = t and t + ha), one multiply each: ceil(H / 2) + 6 cycles per input for
  H = N / 2 unique taps. History in four duplicated LUTRAMs (four reads per
  cycle); a 4-entry output FIFO lets the next input's MAC overlap the drain.
  16-bit samples in and out, saturated; products are magnitude x magnitude
  with the sign applied after (the Fft64 idiom).
  """

  def taps(:hb2), do: MimoHalow.Model.Fixed.Decim4.h2()
  def taps(:hb1), do: MimoHalow.Model.Fixed.Decim4.h1()

  # Unique side taps g[0..H-1] as {sign, |g|} (18 bits), padded to 16.
  def coef_rom(h, hh) do
    g = h |> Enum.with_index() |> Enum.filter(fn {_, k} -> rem(k, 2) == 0 end) |> Enum.map(&elem(&1, 0))

    for j <- 0..15 do
      if j < hh do
        v = Enum.at(g, j)
        if v < 0, do: Bitwise.bor(Bitwise.bsl(1, 17), -v), else: v
      else
        0
      end
    end
  end

  defmacro __using__(opts) do
    h = taps(Keyword.fetch!(opts, :taps))
    q = Keyword.fetch!(opts, :q)
    nt = length(h)
    c = div(nt - 1, 2)
    n = div(nt + 1, 2)
    hh = div(n, 2)
    ha = div(hh + 1, 2)
    d = div(c - 1, 2)
    flush = div(nt - 1, 2)
    sh = q - 1
    rnd = Bitwise.bsl(1, sh - 1)
    rom = coef_rom(h, hh)

    body =
    quote do
      use Hw.Component

      clock(:clk, freq: 32.0)

      input(:start, 1)
      input(:i_valid, 1)
      input(:i_i, 16)
      input(:i_q, 16)
      input(:i_last, 1)
      input(:o_ready, 1)

      output(:i_ready, 1)
      output(:o_valid, 1)
      output(:o_i, 16)
      output(:o_q, 16)
      output(:o_last, 1)

      memory(:x0, width: 32, depth: 32, sync_read: :clk, init: List.duplicate(0, 32))
      memory(:x1, width: 32, depth: 32, sync_read: :clk, init: List.duplicate(0, 32))
      memory(:x2, width: 32, depth: 32, sync_read: :clk, init: List.duplicate(0, 32))
      memory(:x3, width: 32, depth: 32, sync_read: :clk, init: List.duplicate(0, 32))
      memory(:ca, width: 18, depth: 16, sync_read: :clk, init: unquote(rom))
      memory(:cb, width: 18, depth: 16, sync_read: :clk, init: unquote(rom))

      wire(:wp, 5, init: 0)
      wire(:st, 3, init: 0)
      wire(:t, 4, init: 0)
      wire(:fl, 6, init: 0)
      wire(:flushing, 1, init: 0)
      wire(:fin, 1, init: 0)
      wire(:done, 1, init: 0)
      wire(:v1, 1, init: 0)
      wire(:v2, 1, init: 0)
      wire(:v3, 1, init: 0)
      wire(:b1, 1, init: 0)
      wire(:b2, 1, init: 0)
      wire(:pia, 17, init: 0)
      wire(:pqa, 17, init: 0)
      wire(:pib, 17, init: 0)
      wire(:pqb, 17, init: 0)
      wire(:cga, 18, init: 0)
      wire(:cgb, 18, init: 0)
      wire(:mia, 34, init: 0)
      wire(:mqa, 34, init: 0)
      wire(:mib, 34, init: 0)
      wire(:mqb, 34, init: 0)
      wire(:sia, 1, init: 0)
      wire(:sqa, 1, init: 0)
      wire(:sib, 1, init: 0)
      wire(:sqb, 1, init: 0)
      wire(:acci, 40, init: 0)
      wire(:accq, 40, init: 0)
      wire(:f0, 33, init: 0)
      wire(:f1, 33, init: 0)
      wire(:f2, 33, init: 0)
      wire(:f3, 33, init: 0)
      wire(:fw, 2, init: 0)
      wire(:fr, 2, init: 0)
      wire(:fc, 3, init: 0)

      wire(:xi, 16)
      wire(:xq, 16)
      wire(:jb, 5)
      wire(:a0, 5)
      wire(:r0, 32)
      wire(:r1, 32)
      wire(:r2, 32)
      wire(:r3, 32)
      wire(:qa, 18)
      wire(:qb, 18)
      wire(:sa_i, 17)
      wire(:sa_q, 17)
      wire(:sb_i, 17)
      wire(:sb_q, 17)
      wire(:ua_i, 17)
      wire(:ua_q, 17)
      wire(:ub_i, 17)
      wire(:ub_q, 17)
      wire(:pa_i, 34)
      wire(:pa_q, 34)
      wire(:pb_i, 34)
      wire(:pb_q, 34)
      wire(:za_i, 40)
      wire(:za_q, 40)
      wire(:zb_i, 40)
      wire(:zb_q, 40)
      wire(:ta_i, 40)
      wire(:ta_q, 40)
      wire(:tb_i, 40)
      wire(:tb_q, 40)
      wire(:ti, 40)
      wire(:tq, 40)
      wire(:ri, 40)
      wire(:rq, 40)
      wire(:ei, 16)
      wire(:eq, 16)
      wire(:yi, 16)
      wire(:yq, 16)
      wire(:room2, 1)
      wire(:fhead, 33)
      wire(:take, 1)
      wire(:ev, 33)
      wire(:drained, 1)
      wire(:push, 1)
      wire(:zero1, 1)
      wire(:od, 33)

      comb do
        zero1 = 0

        xi =
          if flushing == 1 do
            0
          else
            i_i
          end

        xq =
          if flushing == 1 do
            0
          else
            i_q
          end

        jb = t + unquote(ha)

        # Lane a's port is free while the MAC drains: read x[m - d] then.
        a0 =
          if st == 2 do
            wp - unquote(d)
          else
            wp - t
          end

        drained =
          if v1 == 0 and v2 == 0 and v3 == 0 do
            1
          else
            0
          end

        push =
          if st == 2 and drained == 1 do
            1
          else
            0
          end

        r0 = x0[a0]
        r1 = x1[wp - unquote(n - 1) + t]
        r2 = x2[wp - jb]
        r3 = x3[wp - unquote(n - 1) + jb]
        qa = ca[t]
        qb = cb[jb]

        # Symmetric pre-adds, 17 bits.
        sa_i = {r0[31..31], r0[31..16]} + {r1[31..31], r1[31..16]}
        sa_q = {r0[15..15], r0[15..0]} + {r1[15..15], r1[15..0]}
        sb_i = {r2[31..31], r2[31..16]} + {r3[31..31], r3[31..16]}
        sb_q = {r2[15..15], r2[15..0]} + {r3[15..15], r3[15..0]}

        ua_i =
          if pia[16..16] == 1 do
            0 - pia
          else
            pia
          end

        ua_q =
          if pqa[16..16] == 1 do
            0 - pqa
          else
            pqa
          end

        ub_i =
          if pib[16..16] == 1 do
            0 - pib
          else
            pib
          end

        ub_q =
          if pqb[16..16] == 1 do
            0 - pqb
          else
            pqb
          end

        pa_i = ua_i * cga[16..0]
        pa_q = ua_q * cga[16..0]
        pb_i = ub_i * cgb[16..0]
        pb_q = ub_q * cgb[16..0]

        # Signed 40-bit terms from the registered magnitudes.
        za_i = mia
        za_q = mqa
        zb_i = mib
        zb_q = mqb

        ta_i =
          if sia == 1 do
            0 - za_i
          else
            za_i
          end

        ta_q =
          if sqa == 1 do
            0 - za_q
          else
            za_q
          end

        tb_i =
          if sib == 1 do
            0 - zb_i
          else
            zb_i
          end

        tb_q =
          if sqb == 1 do
            0 - zb_q
          else
            zb_q
          end

        # Rounded even output: (|acc| + 2^(sh-1)) >> sh, sign back, saturate.
        ti =
          if acci[39..39] == 1 do
            0 - acci
          else
            acci
          end

        tq =
          if accq[39..39] == 1 do
            0 - accq
          else
            accq
          end

        ri = (ti + unquote(rnd)) >>> unquote(sh)
        rq = (tq + unquote(rnd)) >>> unquote(sh)

        ei =
          if ri > 32767 do
            32767
          else
            ri[15..0]
          end

        eq =
          if rq > 32767 do
            32767
          else
            rq[15..0]
          end

        yi =
          if acci[39..39] == 1 do
            0 - ei
          else
            ei
          end

        yq =
          if accq[39..39] == 1 do
            0 - eq
          else
            eq
          end

        ev = {yi, yq, zero1}
        od = {r0, fin}

        room2 =
          if fc <= 2 do
            1
          else
            0
          end

        fhead =
          case fr do
            0 -> f0
            1 -> f1
            2 -> f2
            _ -> f3
          end

        take =
          if fc != 0 and o_ready == 1 do
            1
          else
            0
          end

        i_ready =
          if st == 0 and flushing == 0 and done == 0 and room2 == 1 do
            1
          else
            0
          end

        o_valid =
          if fc != 0 do
            1
          else
            0
          end

        o_i = fhead[32..17]
        o_q = fhead[16..1]
        o_last = fhead[0..0]
      end


      on :clk do
        if start == 1 do
          wp = 0
          st = 0
          t = 0
          fl = 0
          flushing = 0
          fin = 0
          done = 0
          v1 = 0
          v2 = 0
          v3 = 0
          fw = 0
          fr = 0
          fc = 0
        else
          v1 = 0
          b1 = 0

          case st do
            0 ->
              # Accept an input (or a flush zero) when two FIFO slots are free.
              if room2 == 1 and done == 0 and (flushing == 1 or i_valid == 1) do
                x0[wp + 1] = {xi, xq}
                x1[wp + 1] = {xi, xq}
                x2[wp + 1] = {xi, xq}
                x3[wp + 1] = {xi, xq}
                wp = wp + 1
                acci = 0
                accq = 0
                t = 0
                fin = 0
                st = 1

                if flushing == 0 do
                  if i_last == 1 do
                    flushing = 1
                    fl = unquote(flush)
                  end
                else
                  fl = fl - 1

                  if fl == 1 do
                    fin = 1
                    done = 1
                  end
                end
              end

            1 ->
              # Reads for j = t (lane a) and t + ha (lane b) are out this cycle.
              v1 = 1

              if jb < unquote(hh) do
                b1 = 1
              end

              if t + 1 == unquote(ha) do
                st = 2
              else
                t = t + 1
              end

            2 ->
              # Drained: even from acc, odd from r0 (read since entering st 2).
              if drained == 1 do
                st = 0
              end

            _ ->
              st = 0
          end

          # MAC pipeline. Stage 1: latch pre-adds and coefficients.
          v2 = v1
          b2 = b1

          if v1 == 1 do
            pia = sa_i
            pqa = sa_q
            pib = sb_i
            pqb = sb_q
            cga = qa
            cgb = qb
          end

          # Stage 2: products, signs (lane b zero past H).
          v3 = v2

          if v2 == 1 do
            mia = pa_i
            mqa = pa_q
            sia = bxor(pia[16..16], cga[17..17])
            sqa = bxor(pqa[16..16], cga[17..17])

            if b2 == 1 do
              mib = pb_i
              mqb = pb_q
              sib = bxor(pib[16..16], cgb[17..17])
              sqb = bxor(pqb[16..16], cgb[17..17])
            else
              mib = 0
              mqb = 0
              sib = 0
              sqb = 0
            end
          end

          # Stage 3: accumulate.
          if v3 == 1 do
            acci = acci + ta_i + tb_i
            accq = accq + ta_q + tb_q
          end

          # FIFO: push even then odd when drained, pop on take.
          if push == 1 do
            case fw do
              0 ->
                f0 = ev
                f1 = od

              1 ->
                f1 = ev
                f2 = od

              2 ->
                f2 = ev
                f3 = od

              _ ->
                f3 = ev
                f0 = od
            end

            fw = fw + 2
          end

          if take == 1 do
            fr = fr + 1
          end

          if push == 1 and take == 1 do
            fc = fc + 1
          else
            if push == 1 do
              fc = fc + 2
            else
              if take == 1 do
                fc = fc - 1
              end
            end
          end
        end
      end
    end

    # The EHDL DSL parser matches plain variables ({name, _, nil}); drop the
    # macro's hygiene context so the generated body reads like hand-written.
    Macro.prewalk(body, fn
      {name, meta, ctx} when is_atom(name) and is_atom(ctx) -> {name, meta, nil}
      other -> other
    end)
  end
end

defmodule MimoHalow.Hw.Tx.HbUp2 do
  @moduledoc "x2 half-band interpolator, Decim4.h2 (59 taps, Q17): 2 -> 4 MS/s."
  use MimoHalow.Hw.Tx.HbUp, taps: :hb2, q: 17
end

defmodule MimoHalow.Hw.Tx.HbUp1 do
  @moduledoc "x2 half-band interpolator, Decim4.h1 (15 taps, Q15): 4 -> 8 MS/s."
  use MimoHalow.Hw.Tx.HbUp, taps: :hb1, q: 15
end

defmodule MimoHalow.Hw.Tx.Interp4 do
  @moduledoc """
  2 -> 8 MS/s for the transmit chain, twin of `S1g.Air.interp4/1`: `HbUp2`
  then `HbUp1`, then 16-bit (4 fraction bits) to the 12-bit TX port word,
  `sat12((|y| + 8) >> 4)` with the sign put back. Output pulled with
  `o_ready` (the TX port's sample request); `o_last` on the final sample
  (4n + 130 outputs for n inputs).
  """
  use Hw.Component

  clock(:clk, freq: 32.0)

  input(:start, 1)
  input(:i_valid, 1)
  input(:i_i, 16)
  input(:i_q, 16)
  input(:i_last, 1)
  input(:o_ready, 1)

  output(:i_ready, 1)
  output(:o_valid, 1)
  output(:o_i, 12)
  output(:o_q, 12)
  output(:o_last, 1)

  wire(:ab_valid, 1)
  wire(:ab_ready, 1)
  wire(:ab_i, 16)
  wire(:ab_q, 16)
  wire(:ab_last, 1)
  wire(:b_i, 16)
  wire(:b_q, 16)
  wire(:mi, 16)
  wire(:mq, 16)
  wire(:ni, 16)
  wire(:nq, 16)
  wire(:ci, 12)
  wire(:cq, 12)

  instance :hb2, MimoHalow.Hw.Tx.HbUp2,
    clk: :clk, start: :start, i_valid: :i_valid, i_i: :i_i, i_q: :i_q, i_last: :i_last,
    o_ready: :ab_ready, i_ready: :i_ready, o_valid: :ab_valid, o_i: :ab_i, o_q: :ab_q, o_last: :ab_last

  instance :hb1, MimoHalow.Hw.Tx.HbUp1,
    clk: :clk, start: :start, i_valid: :ab_valid, i_i: :ab_i, i_q: :ab_q, i_last: :ab_last,
    o_ready: :o_ready, i_ready: :ab_ready, o_valid: :o_valid, o_i: :b_i, o_q: :b_q, o_last: :o_last

  comb do
    mi =
      if b_i[15..15] == 1 do
        0 - b_i
      else
        b_i
      end

    mq =
      if b_q[15..15] == 1 do
        0 - b_q
      else
        b_q
      end

    ni = (mi + 8) >>> 4
    nq = (mq + 8) >>> 4

    ci =
      if ni > 2047 do
        2047
      else
        ni[11..0]
      end

    cq =
      if nq > 2047 do
        2047
      else
        nq[11..0]
      end

    o_i =
      if b_i[15..15] == 1 do
        0 - ci
      else
        ci
      end

    o_q =
      if b_q[15..15] == 1 do
        0 - cq
      else
        cq
      end
  end
end
