defmodule MimoHalow.Hw.Tx.VPrecoder do
  @moduledoc """
  Single-stream precoder: the transmit block of `:eigen_1ss` (and, with two
  streams, the base of `:svd_2ss`). Bit-exact twin of
  `MimoHalow.Model.Fixed.VPrecode`.

  Input (`Iface.TxSyms`, ready/valid): one mapped point `s` (16-bit) per
  beat, tagged with its FFT bin. Output (`Iface.TxAnt`, ready/valid): two
  beats per input, antenna 0 then antenna 1, each
  `a_r = sat16((s v_r) >> 14)` with `v_r` the Q1.14 steering coefficient of
  that bin.

  The table `vtab` holds `{v1r, v1i, v2r, v2i}` per bin (64 x 64 bits),
  written by the PS through `v_we/v_addr/v_data` (the AXI-Lite register
  file sits in the radio top). Antenna 0's coefficient is `v1`; a bin never
  written transmits zero, so the PS loads the identity column `(1, 0)` for
  plain SISO.

  One point per 7 cycles: accept, table read, latch, then for each antenna
  load the output register and wait for ready. At the 32 MHz fabric clock
  that is 4.5 M points/s against the 2 MHz S1G symbol rate, so the IFFT,
  not this block, sets the pace. Products use the LtfSync
  unsigned-plus-sign-correction idiom.

  Contains a written memory: verified under iverilog only.
  """

  use Hw.Component

  clock :clk, freq: 32.0

  input :enable, 1
  input :s_valid, 1
  input :s_i, 16
  input :s_q, 16
  input :s_bin, 6
  input :s_stream, 1
  input :s_last, 1
  output :s_ready, 1

  input :o_ready, 1
  output :o_valid, 1
  output :o_i, 16
  output :o_q, 16
  output :o_bin, 6
  output :o_ant, 1
  output :o_last, 1

  input :v_we, 1
  input :v_addr, 6
  input :v_data, 64

  memory :vtab, width: 64, depth: 64, sync_read: :clk

  wire :zero16, 16
  wire :zero32, 32

  # --- state ----------------------------------------------------------------------
  wire :st, 2, init: 0
  wire :ant, 1, init: 0
  wire :sr, 16, init: 0
  wire :si, 16, init: 0
  wire :b, 6, init: 0
  wire :lst, 1, init: 0
  wire :v, 64, init: 0
  wire :vrd, 64

  wire :ov, 1, init: 0
  wire :oi, 16, init: 0
  wire :oq, 16, init: 0
  wire :oant, 1, init: 0

  # --- datapath -------------------------------------------------------------------
  wire :vr, 16
  wire :vi, 16
  wire :p_rr_u, 32
  wire :p_rr_ka, 32
  wire :p_rr_kb, 32
  wire :p_rr, 32
  wire :p_ii_u, 32
  wire :p_ii_ka, 32
  wire :p_ii_kb, 32
  wire :p_ii, 32
  wire :p_ri_u, 32
  wire :p_ri_ka, 32
  wire :p_ri_kb, 32
  wire :p_ri, 32
  wire :p_ir_u, 32
  wire :p_ir_ka, 32
  wire :p_ir_kb, 32
  wire :p_ir, 32
  wire :t_r, 33
  wire :t_i, 33
  wire :a_r, 16
  wire :a_i, 16

  comb do
    zero16 = 0
    zero32 = 0

    vrd = vtab[b]

    vr = if ant == 1 do v[31..16] else v[63..48] end
    vi = if ant == 1 do v[15..0] else v[47..32] end

    # (sr + j si)(vr + j vi), signed 16 x 16
    p_rr_u = sr * vr
    p_rr_ka = if sr[15..15] == 1 do {vr, zero16} else zero32 end
    p_rr_kb = if vr[15..15] == 1 do {sr, zero16} else zero32 end
    p_rr = p_rr_u - p_rr_ka - p_rr_kb
    p_ii_u = si * vi
    p_ii_ka = if si[15..15] == 1 do {vi, zero16} else zero32 end
    p_ii_kb = if vi[15..15] == 1 do {si, zero16} else zero32 end
    p_ii = p_ii_u - p_ii_ka - p_ii_kb
    p_ri_u = sr * vi
    p_ri_ka = if sr[15..15] == 1 do {vi, zero16} else zero32 end
    p_ri_kb = if vi[15..15] == 1 do {sr, zero16} else zero32 end
    p_ri = p_ri_u - p_ri_ka - p_ri_kb
    p_ir_u = si * vr
    p_ir_ka = if si[15..15] == 1 do {vr, zero16} else zero32 end
    p_ir_kb = if vr[15..15] == 1 do {si, zero16} else zero32 end
    p_ir = p_ir_u - p_ir_ka - p_ir_kb

    t_r = {replicate(p_rr[31..31], 1), p_rr} - {replicate(p_ii[31..31], 1), p_ii}
    t_i = {replicate(p_ri[31..31], 1), p_ri} + {replicate(p_ir[31..31], 1), p_ir}

    # sat16(t >> 14) = t[29..14] when t[32..29] is all 0 or all 1, else saturate on t[32].
    a_r = if t_r[32..29] == 0 or t_r[32..29] == 15 do t_r[29..14] else (if t_r[32..32] == 1 do 32768 else 32767 end) end
    a_i = if t_i[32..29] == 0 or t_i[32..29] == 15 do t_i[29..14] else (if t_i[32..32] == 1 do 32768 else 32767 end) end

    s_ready = if enable == 1 and st == 0 do 1 else 0 end
    o_valid = ov
    o_i = oi
    o_q = oq
    o_bin = b
    o_ant = oant
    o_last = if lst == 1 and oant == 1 do 1 else 0 end
  end

  on :clk do
    if v_we == 1 do
      vtab[v_addr] = v_data
    end

    case st do
      0 ->
        if enable == 1 and s_valid == 1 do
          sr = s_i
          si = s_q
          b = s_bin
          lst = s_last
          ant = 0
          st = 1
        end

      1 ->
        # vtab[b] is read on this edge.
        st = 2

      2 ->
        v = vrd
        st = 3

      3 ->
        if ov == 0 do
          ov = 1
          oi = a_r
          oq = a_i
          oant = ant
        else
          if o_ready == 1 do
            ov = 0
            if ant == 0 do
              ant = 1
            else
              st = 0
            end
          end
        end
    end
  end
end
