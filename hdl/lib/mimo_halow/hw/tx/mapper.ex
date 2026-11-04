defmodule MimoHalow.Hw.Tx.Mapper do
  @moduledoc """
  S1G 2 MHz data-symbol interleaver and constellation mapper, transmit side:
  coded bits in (one per beat), 52 data points per OFDM symbol out (one per
  beat) with their FFT bin. Twin of `Coding.interleave/3` + `Qam.map/2` in
  `MimoHalow.Model.S1g.Ppdu.data_tones/5`.

  `mod` (latched by `start`): 0 BPSK, 1 QPSK, 2 16-QAM, 3 64-QAM, 4 256-QAM.
  Ncbps = 52 * Nbpsc. Write side: coded bit k of a symbol goes to buffer
  position perm(k) (ROM from `Coding.perm/5`, address {mod, k}) in one half of
  a ping-pong buffer, so the encoder fills symbol n + 1 while symbol n is
  mapped. Read side: positions in order, Nbpsc bits per point, the first half
  of each group on I (first bit MSB), the second on Q, Gray to binary, level
  2b - (2^n - 1). Output levels are odd integers in -15..15 (signed 5 bit),
  unscaled: k_mod belongs with the IFFT normalisation downstream. BPSK puts
  its level on I, Q = 0. `o_last` marks point 51 of a symbol.

  Data tone j (0..51) is k = -28..28 minus 0 and the pilots +-7, +-21; its bin
  (k mod 64) is j + 36 + segment, segment 0..5 over j < 7, < 20, < 26, < 32,
  < 45, else.
  """
  use Hw.Component

  alias MimoHalow.Model.S1g.{Coding, Params}

  @nbpsc [1, 2, 4, 6, 8]
  @rom (for m <- 0..7, k <- 0..511 do
          if m < 5 do
            nb = Enum.at(@nbpsc, m)
            n = 52 * nb
            if k < n, do: Enum.at(Coding.perm(Params.interleaver(2, nb), nb, n), k), else: 0
          else
            0
          end
        end)

  clock(:clk, freq: 32.0)

  input(:start, 1)
  input(:mod, 3)
  input(:i_valid, 1)
  input(:i_bit, 1)
  input(:o_ready, 1)

  output(:i_ready, 1)
  output(:o_valid, 1)
  output(:o_i, 5)
  output(:o_q, 5)
  output(:o_bin, 6)
  output(:o_last, 1)

  memory(:perm, width: 9, depth: 4096, sync_read: :clk, init: @rom)
  memory(:buf, width: 1, depth: 1024, sync_read: :clk)

  wire(:act, 1, init: 0)
  wire(:r_mod, 3, init: 0)

  # Write side.
  wire(:wh, 1, init: 0)
  wire(:wk, 9, init: 0)
  wire(:wpend, 1, init: 0)
  wire(:wbit, 1, init: 0)
  wire(:whd, 1, init: 0)
  wire(:wlast, 1, init: 0)
  wire(:full0, 1, init: 0)
  wire(:full1, 1, init: 0)

  # Read side.
  wire(:rh, 1, init: 0)
  wire(:ra, 9, init: 0)
  wire(:rs, 2, init: 0)
  wire(:bi, 4, init: 0)
  wire(:rv, 1, init: 0)
  wire(:rl, 1, init: 0)
  wire(:acc, 8, init: 0)
  wire(:form, 1, init: 0)
  wire(:j, 6, init: 0)
  wire(:ov, 1, init: 0)
  wire(:oi, 5, init: 0)
  wire(:oq, 5, init: 0)
  wire(:ob, 6, init: 0)
  wire(:ol, 1, init: 0)

  # Combinational.
  wire(:nb, 4)
  wire(:ncbps, 9)
  wire(:wfree, 1)
  wire(:rfull, 1)
  wire(:pq, 9)
  wire(:rq, 1)
  wire(:gi, 4)
  wire(:gq, 4)
  wire(:bi4, 4)
  wire(:bq4, 4)
  wire(:off, 5)
  wire(:li, 5)
  wire(:b5i, 5)
  wire(:b5q, 5)
  wire(:lq, 5)
  wire(:seg, 6)

  comb do
    nb =
      case r_mod do
        0 -> 1
        1 -> 2
        2 -> 4
        3 -> 6
        _ -> 8
      end

    ncbps =
      case r_mod do
        0 -> 52
        1 -> 104
        2 -> 208
        3 -> 312
        _ -> 416
      end

    wfree =
      if wh == 0 do
        ~~~full0
      else
        ~~~full1
      end

    rfull =
      if rh == 0 do
        full0
      else
        full1
      end

    pq = perm[{r_mod, wk}]
    rq = buf[{rh, ra}]

    # Gray groups, zero-extended to 4 bits (a leading 0 decodes the same).
    gi =
      case r_mod do
        0 -> acc[0..0]
        1 -> acc[1..1]
        2 -> acc[3..2]
        3 -> acc[5..3]
        _ -> acc[7..4]
      end

    gq =
      case r_mod do
        0 -> 0
        1 -> acc[0..0]
        2 -> acc[1..0]
        3 -> acc[2..0]
        _ -> acc[3..0]
      end

    bi4 = {gi[3..3], bxor(gi[3..3], gi[2..2]), bxor(bxor(gi[3..3], gi[2..2]), gi[1..1]), bxor(bxor(bxor(gi[3..3], gi[2..2]), gi[1..1]), gi[0..0])}
    bq4 = {gq[3..3], bxor(gq[3..3], gq[2..2]), bxor(bxor(gq[3..3], gq[2..2]), gq[1..1]), bxor(bxor(bxor(gq[3..3], gq[2..2]), gq[1..1]), gq[0..0])}

    # 2^n - 1 for n bits per axis (BPSK: one bit on I).
    off =
      case r_mod do
        0 -> 1
        1 -> 1
        2 -> 3
        3 -> 7
        _ -> 15
      end

    b5i = bi4
    b5q = bq4
    li = b5i + b5i - off

    lq =
      if r_mod == 0 do
        0
      else
        b5q + b5q - off
      end

    seg =
      if j < 7 do
        36
      else
        if j < 20 do
          37
        else
          if j < 26 do
            38
          else
            if j < 32 do
              39
            else
              if j < 45 do
                40
              else
                41
              end
            end
          end
        end
      end

    i_ready = act == 1 and wfree == 1
    o_valid = ov
    o_i = oi
    o_q = oq
    o_bin = ob
    o_last = ol
  end

  on :clk do
    if start == 1 do
      act = 1
      r_mod = mod
      wh = 0
      wk = 0
      wpend = 0
      wlast = 0
      full0 = 0
      full1 = 0
      rh = 0
      ra = 0
      rs = 0
      bi = 0
      rv = 0
      rl = 0
      form = 0
      j = 0
      ov = 0
    else
      # --- write side: accept a bit, write it at perm(k) next cycle ---
      wpend = 0
      wlast = 0

      if act == 1 and wfree == 1 and i_valid == 1 do
        wbit = i_bit
        whd = wh
        wpend = 1

        if wk + 1 == ncbps do
          wk = 0
          wh = ~~~wh
          wlast = 1
        else
          wk = wk + 1
        end
      end

      if wpend == 1 do
        buf[{whd, pq}] = wbit

        if wlast == 1 do
          if whd == 0 do
            full0 = 1
          else
            full1 = 1
          end
        end
      end

      # --- read side ---
      if ov == 1 and o_ready == 1 do
        ov = 0
      end

      # Bit data from the previous cycle's read.
      rv = 0
      rl = 0
      form = 0

      if rv == 1 do
        acc = {acc[6..0], rq}

        if rl == 1 do
          form = 1
        end
      end

      # Point formed from the completed group.
      if form == 1 do
        ov = 1
        oi = li
        oq = lq
        ob = j + seg

        if j == 51 do
          ol = 1
        else
          ol = 0
        end
      end

      case rs do
        0 ->
          if rfull == 1 do
            rs = 1
            bi = 0
          end

        1 ->
          # Issue one read per cycle for this point's Nbpsc bits.
          rv = 1
          ra = ra + 1

          if bi + 1 == nb do
            rl = 1
            rs = 2
          else
            bi = bi + 1
          end

        2 ->
          # Wait until the point is out and taken.
          if ov == 1 and o_ready == 1 do
            if j == 51 do
              j = 0
              ra = 0
              rs = 0
              rh = ~~~rh

              if rh == 0 do
                full0 = 0
              else
                full1 = 0
              end
            else
              j = j + 1
              bi = 0
              rs = 1
            end
          end

        _ ->
          rs = 0
      end
    end
  end
end
