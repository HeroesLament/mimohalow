defmodule MimoHalow.Hw.Rx.ByteOut do
  @moduledoc """
  Viterbi bits -> PSDU bytes: the end of the S1G receive chain. Twin of
  `MimoHalow.Model.Fixed.DataDec.descramble/1` + `psdu/5`.

  On `sig_done` (not discarded) the PSDU length latches: LENGTH bytes, or
  `(ndata Ndbps(MCS) - 14) >> 3` when aggregated. Per decoded bit: the
  first 7 are the scrambler state (shifted in, newest at x1); then each bit
  is descrambled (x7 ^ x4, fed back); bit 7 (reserved SERVICE bit) is
  dropped; bits 8.. are packed LSB first into bytes, `b_last` on byte
  LENGTH - 1, the rest (pad, tail) dropped.
  """

  use Hw.Component

  clock :clk, freq: 32.0

  input :enable, 1
  input :v_valid, 1
  input :v_bit, 1
  input :sig_done, 1
  input :sig_discard, 1
  input :f_mcs, 4
  input :f_length, 9
  input :f_aggr, 1
  input :f_ndata, 11

  output :b_valid, 1
  output :b_byte, 8
  output :b_last, 1
  output :b_len, 16

  wire :zero16, 16
  wire :ndb, 9
  wire :prod, 20
  wire :alen, 20
  wire :len, 16, init: 0
  wire :act, 1, init: 0
  wire :bi, 4, init: 0
  wire :st, 7, init: 0
  wire :sb, 1
  wire :db, 1
  wire :acc, 8, init: 0
  wire :nb, 3, init: 0
  wire :nbytes, 16, init: 0
  wire :ov, 1, init: 0
  wire :obyte, 8, init: 0
  wire :olast, 1, init: 0
  wire :nacc, 8

  comb do
    zero16 = 0
    ndb = 0
    case f_mcs do
      0 ->
        ndb = 26
      1 ->
        ndb = 52
      2 ->
        ndb = 78
      3 ->
        ndb = 104
      4 ->
        ndb = 156
      5 ->
        ndb = 208
      6 ->
        ndb = 234
      7 ->
        ndb = 260
      8 ->
        ndb = 312
    end
    prod = f_ndata * ndb
    alen = prod - 14
    sb = bxor(st[6..6], st[3..3])
    db = bxor(v_bit, sb)
    nacc = acc
    case nb do
      0 ->
        nacc = {acc[7..1], db}
      1 ->
        nacc = {acc[7..2], db, acc[0..0]}
      2 ->
        nacc = {acc[7..3], db, acc[1..0]}
      3 ->
        nacc = {acc[7..4], db, acc[2..0]}
      4 ->
        nacc = {acc[7..5], db, acc[3..0]}
      5 ->
        nacc = {acc[7..6], db, acc[4..0]}
      6 ->
        nacc = {acc[7..7], db, acc[5..0]}
      7 ->
        nacc = {db, acc[6..0]}
    end

    b_valid = ov
    b_byte = obyte
    b_last = olast
    b_len = len
  end

  on :clk do
    ov = 0
    if enable == 1 and sig_done == 1 do
      if sig_discard == 0 do
        act = 1
        len = if f_aggr == 1 do alen[18..3] else {zero16[6..0], f_length} end
      else
        act = 0
      end
      bi = 0
      nb = 0
      nbytes = 0
    end
    if enable == 1 and v_valid == 1 and act == 1 do
      if bi < 7 do
        st = {st[5..0], v_bit}
        bi = bi + 1
      else
        st = {st[5..0], sb}
        if bi == 7 do
          bi = 8
        else
          if nbytes != len do
            acc = nacc
            nb = nb + 1
            if nb == 7 do
              ov = 1
              obyte = nacc
              olast = if nbytes == len - 1 do 1 else 0 end
              nbytes = nbytes + 1
            end
          end
        end
      end
    end
  end
end
