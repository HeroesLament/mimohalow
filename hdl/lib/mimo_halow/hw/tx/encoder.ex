defmodule MimoHalow.Hw.Tx.Encoder do
  @moduledoc """
  S1G DATA field bit chain, transmit side: SERVICE(8 zero bits) | PSDU (LSB
  first per byte) | pad zeros | tail(6), scrambled (x^7 + x^4 + 1, from
  `seed`), tail forced to 0 after scrambling, BCC K = 7 (g0 = 133o -> A,
  g1 = 171o -> B), punctured by `rate` (0: 1/2, 1: 2/3, 2: 3/4, 3: 5/6).
  Twin of the data path in `MimoHalow.Model.S1g.Ppdu.data_tones/5` up to the
  interleaver.

  `start` latches `seed`, `rate`, `nbits` (Nsym * Ndbps) and `len` (PSDU
  bytes, FCS included). PSDU bytes arrive on `in_valid` / `in_ready` /
  `in_byte`; coded bits leave one per beat on `o_valid` / `o_ready` / `o_bit`
  in A0 B0 A1 B1 ... order, punctured positions skipped. `done` pulses once
  after the last coded bit is taken.

  Two stages: the source / scrambler / BCC fills a one-pair buffer (A, B and
  their keep flags) when it is empty; the serialiser emits A then B. Three
  cycles per information bit at most, so 5.3 Mbit/s at 16 MHz (S1G 2 MHz MCS8
  needs 3.9).
  """
  use Hw.Component

  clock(:clk, freq: 32.0)

  input(:start, 1)
  input(:seed, 7)
  input(:rate, 2)
  input(:nbits, 16)
  input(:len, 10)
  input(:in_valid, 1)
  input(:in_byte, 8)
  input(:o_ready, 1)

  output(:in_ready, 1)
  output(:o_valid, 1)
  output(:o_bit, 1)
  output(:busy, 1)
  output(:done, 1)

  # Latched parameters and source state.
  wire(:act, 1, init: 0)
  wire(:r_rate, 2, init: 0)
  wire(:r_nbits, 16, init: 0)
  wire(:r_len, 10, init: 0)
  wire(:k, 16, init: 0)
  wire(:scr, 7, init: 0)
  wire(:sr, 6, init: 0)
  wire(:pc, 4, init: 0)
  wire(:byte, 8, init: 0)
  wire(:bf, 1, init: 0)
  wire(:boff, 3, init: 0)
  wire(:nused, 10, init: 0)
  wire(:nload, 10, init: 0)

  # Pair buffer and serialiser.
  wire(:pv, 1, init: 0)
  wire(:sel, 1, init: 0)
  wire(:pa, 1, init: 0)
  wire(:pb, 1, init: 0)
  wire(:ka, 1, init: 0)
  wire(:kb, 1, init: 0)
  wire(:dn, 1, init: 0)

  # Combinational.
  wire(:in_psdu, 1)
  wire(:is_tail, 1)
  wire(:dbit, 1)
  wire(:fb, 1)
  wire(:us, 1)
  wire(:w, 7)
  wire(:pat, 10)
  wire(:plen, 4)
  wire(:pc2, 4)
  wire(:want_byte, 1)
  wire(:stall, 1)
  wire(:cur_keep, 1)
  wire(:cur_bit, 1)

  comb do
    # Keep pattern over A0 B0 A1 B1 ..., bit i = position i.
    pat =
      case r_rate do
        0 -> 0b11
        1 -> 0b0111
        2 -> 0b100111
        _ -> 0b1001100111
      end

    plen =
      case r_rate do
        0 -> 2
        1 -> 4
        2 -> 6
        _ -> 10
      end

    pc2 =
      if pc + 2 >= plen do
        pc + 2 - plen
      else
        pc + 2
      end

    in_psdu =
      if k >= 8 and nused < r_len do
        1
      else
        0
      end

    is_tail =
      if k + 6 >= r_nbits do
        1
      else
        0
      end

    dbit = band(byte >>> boff, 1)
    fb = bxor(scr[6..6], scr[3..3])

    us =
      if is_tail == 1 do
        0
      else
        if in_psdu == 1 do
          bxor(dbit, fb)
        else
          fb
        end
      end

    w = {us, sr}
    want_byte = act == 1 and bf == 0 and nload < r_len
    stall = in_psdu == 1 and bf == 0

    cur_keep =
      if sel == 0 do
        ka
      else
        kb
      end

    cur_bit =
      if sel == 0 do
        pa
      else
        pb
      end

    in_ready = want_byte
    o_valid = pv == 1 and cur_keep == 1
    o_bit = cur_bit
    busy = act
    done = dn
  end

  on :clk do
    dn = 0

    if start == 1 do
      act = 1
      r_rate = rate
      r_nbits = nbits
      r_len = len
      k = 0
      scr = seed
      sr = 0
      pc = 0
      bf = 0
      boff = 0
      nused = 0
      nload = 0
      pv = 0
      sel = 0
    else
      # Byte prefetch (one deep).
      if want_byte == 1 and in_valid == 1 do
        byte = in_byte
        bf = 1
        nload = nload + 1
      end

      # Serialiser: A then B; a punctured position takes a cycle, no beat.
      if pv == 1 and (cur_keep == 0 or o_ready == 1) do
        if sel == 0 do
          sel = 1
        else
          sel = 0
          pv = 0

          if act == 0 do
            dn = 1
          end
        end
      end

      # Source: one information bit into the empty pair buffer.
      if act == 1 and pv == 0 and stall == 0 do
        if k < r_nbits do
          pa = parity(band(w, 0o133))
          pb = parity(band(w, 0o171))
          ka = band(pat >>> pc, 1)
          kb = band(pat >>> (pc + 1), 1)
          pv = 1
          sel = 0
          pc = pc2
          sr = w[6..1]
          scr = {scr[5..0], fb}
          k = k + 1

          if in_psdu == 1 do
            boff = boff + 1

            if boff == 7 do
              bf = 0
              nused = nused + 1
            end
          end

          if k + 1 == r_nbits do
            act = 0
          end
        end
      end
    end
  end
end
