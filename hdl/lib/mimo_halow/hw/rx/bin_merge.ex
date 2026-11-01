defmodule MimoHalow.Hw.Rx.BinMerge do
  @moduledoc """
  Two FFT output streams (one per receive chain, fed by `SymFeed`s with the
  same sync, so their bins arrive together) into the one stream the MIMO
  detector takes: each symbol as chain 0's 64 bins then chain 1's, in FFT
  output (bit-reversed) order, one bin per 4 cycles.

  Each chain writes a 2 x 64 ping-pong buffer at `{wpar, pos}`; position 63
  of chain 0 marks the symbol complete (`ready[wpar]`, tag latched) and
  flips `wpar`. The reader replays a complete symbol in 128 x 4 = 512
  cycles, so symbols must be at least 512 cycles apart (64 samples at
  2 MS/s on a 32 MHz clock is 1024). A symbol completing while its buffer is
  still unread is counted in `overrun`.
  """

  use Hw.Component

  clock :clk, freq: 32.0

  input :enable, 1
  input :a_valid, 1
  input :a_i, 26
  input :a_q, 26
  input :a_pos, 6
  input :a_tag, 12
  input :b_valid, 1
  input :b_i, 26
  input :b_q, 26
  input :b_pos, 6

  output :o_valid, 1
  output :o_i, 26
  output :o_q, 26
  output :o_bin, 6
  output :o_chain, 1
  output :o_tag, 12
  output :overrun, 8

  memory :abuf, width: 52, depth: 128, sync_read: :clk
  memory :bbuf, width: 52, depth: 128, sync_read: :clk

  wire :wpar, 1, init: 0
  wire :rdy0, 1, init: 0
  wire :rdy1, 1, init: 0
  wire :tag0, 12, init: 0
  wire :tag1, 12, init: 0
  wire :ovr, 8, init: 0
  wire :waddr_a, 7
  wire :waddr_b, 7

  wire :rpar, 1, init: 0
  wire :busy, 1, init: 0
  wire :rc, 7, init: 0
  wire :ph, 2, init: 0
  wire :rv, 1, init: 0
  wire :rch, 1, init: 0
  wire :rpos, 6, init: 0
  wire :raddr, 7
  wire :ard, 52
  wire :brd, 52
  wire :rdy_r, 1
  wire :mi, 26
  wire :mq, 26
  wire :mtag, 12
  wire :mbin, 6

  wire :ov, 1, init: 0
  wire :oi, 26, init: 0
  wire :oq, 26, init: 0
  wire :obin, 6, init: 0
  wire :och, 1, init: 0
  wire :otag, 12, init: 0

  comb do
    waddr_a = {wpar, a_pos}
    waddr_b = {wpar, b_pos}
    raddr = {rpar, rc[5..0]}
    ard = abuf[raddr]
    brd = bbuf[raddr]
    rdy_r = if rpar == 1 do rdy1 else rdy0 end
    mi = if rch == 1 do brd[51..26] else ard[51..26] end
    mq = if rch == 1 do brd[25..0] else ard[25..0] end
    mtag = if rpar == 1 do tag1 else tag0 end
    mbin = {rpos[0..0], rpos[1..1], rpos[2..2], rpos[3..3], rpos[4..4], rpos[5..5]}

    o_valid = ov
    o_i = oi
    o_q = oq
    o_bin = obin
    o_chain = och
    o_tag = otag
    overrun = ovr
  end

  on :clk do
    # write side
    if enable == 1 and a_valid == 1 do
      abuf[waddr_a] = {a_i, a_q}
      if a_pos == 63 do
        if wpar == 1 do
          if rdy1 == 1 do
            ovr = ovr + 1
          end
          rdy1 = 1
          tag1 = a_tag
        else
          if rdy0 == 1 do
            ovr = ovr + 1
          end
          rdy0 = 1
          tag0 = a_tag
        end
        wpar = bnot(wpar)
      end
    end
    if enable == 1 and b_valid == 1 do
      bbuf[waddr_b] = {b_i, b_q}
    end

    # read side: address at ph 0, data at ph 1 -> output register
    ov = 0
    rv = 0
    if busy == 0 do
      if rdy_r == 1 do
        busy = 1
        rc = 0
        ph = 0
      end
    else
      ph = ph + 1
      if ph == 0 do
        rv = 1
        rch = rc[6..6]
        rpos = rc[5..0]
      end
      if ph == 3 do
        rc = rc + 1
        if rc == 127 do
          busy = 0
          rpar = bnot(rpar)
          if rpar == 1 do
            rdy1 = 0
          else
            rdy0 = 0
          end
        end
      end
    end
    if rv == 1 do
      ov = 1
      oi = mi
      oq = mq
      obin = mbin
      och = rch
      otag = mtag
    end
  end
end
