defmodule MimoHalow.Hw.PhyHost do
  @moduledoc """
  PS-facing wrapper of the mimohalow PHY for the LibreSDR board top, in the
  slot OpenOcuSync's `Hw.PhyHost` occupies (same clocks, control word,
  memory window shape). Receive always; transmit through `Tx.TxPhy` when
  CTRL1[14] gives it the TX port (else the top's TX DMA ring path, with
  PS-built samples).

  Two clocks: `axi_clk` (the AXI-Lite slave) and `data_clk` (AD936x
  DATA_CLK, 32 MHz at 8 MS/s 2R2T, where the PHY runs).

      I1/Q1/I2/Q2 at 8 MS/s -> DcBlock -> Decim4 -> Rx.Eig1 -> receive ring
      CTRL3 words -> TX buffer + params -> Tx.TxPhy -> TX port (I1/Q1)

  ## Control (`ctl`, the slave's CTRL1; bits 0..4, 8..13 belong to the top)

      [5]     phy_en      receiver enable
      [6]     dc_bypass   1 = no DC blocker ahead of Decim4 (`Rx.DcBlock`)
      [14]    TX port source: 1 = this PHY (`tx_sel`), 0 = the top's paths
      [31:26] detector energy gate: emin = code << 9

  ## Transmit commands (CTRL3 writes; [31:28] opcode)

      1  buffer word: [23:0] = PSDU bytes 3w..3w+2 ([7:0] first) at the
         buffer write pointer w, which then advances (1024 words)
      2  SIG chunk: [25:24] k, [23:0] -> sig[24k + 23 : 24k] (96 interleaved
         SIG coded bits as `Tx.Ofdm`)
      3  [9:0] nsym, [16:10] scrambler seed, [19:17] mod, [21:20] rate
      4  [15:0] nbits (nsym * Ndbps), [25:16] len (PSDU bytes, FCS included)
      5  start the frame; buffer write pointer -> 0
      6  buffer write pointer -> 0

  Buffer, SIG and parameters are sampled while the frame runs: write the
  next frame only once `tx_busy` (word 4 bit 0) is clear. The AD9363 keying
  and CTRL1[14] stay with the PS.

  ## Memory window (word index of `mem_raddr`)

      0      "MHW2"
      1      [15:0] receive ring write count (entries ever written)
      2      {sync_count, drop_count}
      3      {det_count, 13'b0, early, v_overflow, overrun != 0}
      4      {preempt_count, tx_underruns[7:0], tx_frames[6:0], tx_busy}
             preempt: syncs that re-armed the feeders; underruns saturate
      2048.. receive ring, 2048 entries: entry n at 2048 + (n mod 2048)

  Ring entries (data_clk order):

      SIG    {0, 3'd1, ok, discard, mcs[3:0], aggr, 1'b0, length[8:0], ndata[10:0]}
             bits 27 ok, 26 discard, 25:22 mcs, 21 aggr, 19:11 length, 10:0 ndata
      BYTES  {1, last, n[1:0], 4'b0, b2, b1, b0}   n bytes valid (1..3),
                                                    b0 first; last on the
                                                    PSDU's final entry

  The write count crosses to `axi_clk` in Gray code; the PS keeps its own
  read count (more than 2048 behind means entries were overwritten).
  """

  use Hw.Component

  clock :axi_clk, freq: 100.0
  clock :data_clk, freq: 32.0

  input :ctl, 32
  input :ctrl3, 32
  input :ctrl3_wr, 1
  input :mem_raddr, 15
  output :mem_rdata, 32

  input :valid, 1
  input :i0, 12
  input :q0, 12
  input :i1, 12
  input :q1, 12
  input :tick, 1

  output :o_valid, 1
  output :o_i, 12
  output :o_q, 12
  output :tx_busy, 1
  output :tx_sel, 1
  output :detect, 1
  output :sync_count, 16

  memory :rxr, width: 32, depth: 2048, sync_read: :axi_clk
  memory :txb, width: 24, depth: 1024, sync_read: :data_clk

  wire :zero32, 32
  wire :one1, 1

  # ---- axi_clk side -------------------------------------------------------
  wire :wg_s1, 16, init: 0
  wire :wg_s2, 16, init: 0
  wire :mon0_a, 32, init: 0
  wire :mon1_a, 32, init: 0
  wire :mon2_a, 32, init: 0
  wire :st_q, 32, init: 0
  wire :sel_q, 1, init: 0
  wire :wbin, 16
  wire :gb1, 16
  wire :gb2, 16
  wire :gb3, 16
  wire :st_c, 32
  wire :ring_q, 32

  # ---- transmit, axi_clk side ---------------------------------------------
  wire :t_wp, 10, init: 0
  wire :t_sig, 96, init: 0
  wire :t_par, 22, init: 0
  wire :t_len, 26, init: 0
  wire :t_go, 1, init: 0
  wire :t_op, 4
  wire :t_par_nsym, 10
  wire :t_par_seed, 7
  wire :t_par_mod, 3
  wire :t_par_rate, 2
  wire :t_len_nbits, 16
  wire :t_len_len, 10

  # ---- transmit, data_clk side --------------------------------------------
  wire :x_go, 1
  wire :g_s1, 1, init: 0
  wire :g_s2, 1, init: 0
  wire :g_s3, 1, init: 0
  wire :t_start, 1
  wire :t_baddr, 10
  wire :t_bdata, 24
  wire :t_ov, 1
  wire :t_oi, 12
  wire :t_oq, 12
  wire :t_busy, 1
  wire :t_done, 1
  wire :t_under, 1
  wire :t_cnt, 7, init: 0
  wire :t_und, 8, init: 0

  # ---- data_clk side ------------------------------------------------------
  wire :c_s1, 32, init: 0
  wire :c_s2, 32, init: 0
  wire :phy_en, 1
  wire :dc_bypass, 1
  wire :emin, 32
  wire :wcnt, 16, init: 0
  wire :wgray, 16, init: 0
  wire :wnext, 16
  wire :mon0, 32, init: 0
  wire :mon1, 32, init: 0
  wire :mon2, 32, init: 0
  wire :x_m2, 32
  wire :x_wg, 16
  wire :x_m0, 32
  wire :x_m1, 32
  wire :acc, 24, init: 0
  wire :nb, 2, init: 0
  wire :sig_p, 1, init: 0
  wire :sig_w, 32, init: 0
  wire :sig_e, 32
  wire :byte_e, 32
  wire :bfull, 1
  wire :byte_acc, 24
  wire :ntot, 2
  wire :f_early, 1
  wire :f_ovr, 1
  wire :we, 1
  wire :wd, 32

  # decimator -> receiver
  wire :xv, 1
  wire :xi0, 12
  wire :xq0, 12
  wire :xi1, 12
  wire :xq1, 12
  wire :dv, 1
  wire :di0, 12
  wire :dq0, 12
  wire :di1, 12
  wire :dq1, 12

  # receiver outputs
  wire :r_detect, 1
  wire :r_det_count, 16
  wire :r_done, 1
  wire :r_ts_off, 6
  wire :r_dphi, 24
  wire :r_sync_td, 32
  wire :r_sync_count, 16
  wire :r_drop_count, 16
  wire :r_preempt, 16
  wire :r_overrun, 8
  wire :r_scale, 4
  wire :r_noise, 42
  wire :r_e_valid, 1
  wire :r_e_i, 27
  wire :r_e_q, 27
  wire :r_e_g, 21
  wire :r_e_d, 6
  wire :r_e_j, 11
  wire :r_e_last, 1
  wire :r_e_theta, 16
  wire :r_sig_done, 1
  wire :r_sig_ok, 1
  wire :r_sig_discard, 1
  wire :r_nsym_total, 11
  wire :r_sig_bits, 48
  wire :r_f_mcs, 4
  wire :r_f_length, 9
  wire :r_f_aggr, 1
  wire :r_f_ndata, 11
  wire :r_b_valid, 1
  wire :r_b_byte, 8
  wire :r_b_last, 1
  wire :r_b_len, 16
  wire :r_v_overflow, 1
  wire :r_d_early, 8

  comb do
    zero32 = 0
    one1 = 1

    phy_en = c_s2[5..5]
    dc_bypass = c_s2[6..6]
    emin = {zero32[16..0], c_s2[31..26], zero32[8..0]}
    tx_sel = ctl[14..14]
    o_valid = t_ov
    o_i = t_oi
    o_q = t_oq
    tx_busy = t_busy

    t_op = ctrl3[31..28]
    t_par_nsym = t_par[9..0]
    t_par_seed = t_par[16..10]
    t_par_mod = t_par[19..17]
    t_par_rate = t_par[21..20]
    t_len_nbits = t_len[15..0]
    t_len_len = t_len[25..16]
    x_go = t_go
    t_start = bxor(g_s2, g_s3)
    t_bdata = txb[t_baddr]
    detect = r_detect
    sync_count = r_sync_count

    # Receive ring entries.
    sig_e = {zero32[0..0], zero32[1..0], one1, r_sig_ok, r_sig_discard, r_f_mcs, r_f_aggr, zero32[0..0], r_f_length, r_f_ndata}
    byte_acc = if nb == 0 do {acc[23..8], r_b_byte} else (if nb == 1 do {acc[23..16], r_b_byte, acc[7..0]} else {r_b_byte, acc[15..0]} end) end
    ntot = nb + 1
    bfull = if r_b_valid == 1 and (nb == 2 or r_b_last == 1) do 1 else 0 end
    byte_e = {one1, r_b_last, ntot, zero32[3..0], byte_acc}
    f_early = if r_d_early != 0 do 1 else 0 end
    f_ovr = if r_overrun != 0 do 1 else 0 end
    we = if bfull == 1 or sig_p == 1 do 1 else 0 end
    wd = if bfull == 1 do byte_e else sig_w end
    wnext = wcnt + 1

    # Gray -> binary of the synchronised write count.
    gb1 = bxor(wg_s2, {zero32[0..0], wg_s2[15..1]})
    gb2 = bxor(gb1, {zero32[1..0], gb1[15..2]})
    gb3 = bxor(gb2, {zero32[3..0], gb2[15..4]})
    wbin = bxor(gb3, {zero32[7..0], gb3[15..8]})

    # "MHW2" = 0x4D485732
    st_c = if mem_raddr[3..0] == 1 do {zero32[15..0], wbin} else (if mem_raddr[3..0] == 2 do mon0_a else (if mem_raddr[3..0] == 3 do mon1_a else (if mem_raddr[3..0] == 4 do mon2_a else 1296586546 end) end) end) end
    ring_q = rxr[mem_raddr[10..0]]
    mem_rdata = if sel_q == 1 do ring_q else st_q end

    x_wg = wgray
    x_m0 = mon0
    x_m1 = mon1
    x_m2 = mon2
  end

  on :axi_clk do
    wg_s1 = x_wg
    wg_s2 = wg_s1
    mon0_a = x_m0
    mon1_a = x_m1
    mon2_a = x_m2
    st_q = st_c
    sel_q = mem_raddr[11..11]

    if ctrl3_wr == 1 do
      case t_op do
        1 ->
          txb[t_wp] = ctrl3[23..0]
          t_wp = t_wp + 1

        2 ->
          case ctrl3[25..24] do
            0 -> t_sig = {t_sig[95..24], ctrl3[23..0]}
            1 -> t_sig = {t_sig[95..48], ctrl3[23..0], t_sig[23..0]}
            2 -> t_sig = {t_sig[95..72], ctrl3[23..0], t_sig[47..0]}
            _ -> t_sig = {ctrl3[23..0], t_sig[71..0]}
          end

        3 ->
          t_par = ctrl3[21..0]

        4 ->
          t_len = ctrl3[25..0]

        5 ->
          t_go = bnot(t_go)
          t_wp = 0

        6 ->
          t_wp = 0

        _ ->
          t_wp = t_wp
      end
    end
  end

  on :data_clk do
    c_s1 = ctl
    c_s2 = c_s1
    mon0 = {r_sync_count, r_drop_count}
    mon1 = {r_det_count, zero32[12..0], f_early, r_v_overflow, f_ovr}
    mon2 = {r_preempt, t_und, t_cnt, t_busy}

    g_s1 = x_go
    g_s2 = g_s1
    g_s3 = g_s2
    if t_done == 1 do
      t_cnt = t_cnt + 1
    end
    if t_under == 1 and t_und != 255 do
      t_und = t_und + 1
    end

    # A SIG entry waits for a cycle without a byte entry.
    if r_sig_done == 1 do
      sig_p = 1
      sig_w = sig_e
    end
    if r_b_valid == 1 do
      if bfull == 1 do
        nb = 0
        acc = 0
      else
        nb = nb + 1
        acc = byte_acc
      end
    end
    if we == 1 do
      rxr[wcnt[10..0]] = wd
      wcnt = wnext
      wgray = bxor(wnext, {zero32[0..0], wnext[15..1]})
      if bfull == 0 do
        sig_p = 0
      end
    end
  end

  instance :dcb, MimoHalow.Hw.Rx.DcBlock,
    clk: :data_clk, enable: :phy_en, bypass: :dc_bypass, valid: :valid, i0: :i0, q0: :q0, i1: :i1, q1: :q1,
    o_valid: :xv, o_i0: :xi0, o_q0: :xq0, o_i1: :xi1, o_q1: :xq1

  instance :dec, MimoHalow.Hw.Rx.Decim4,
    clk: :data_clk, enable: :phy_en, valid: :xv, i0: :xi0, q0: :xq0, i1: :xi1, q1: :xq1,
    o_valid: :dv, o_i0: :di0, o_q0: :dq0, o_i1: :di1, o_q1: :dq1

  instance :rxp, MimoHalow.Hw.Rx.Eig1,
    clk: :data_clk, enable: :phy_en, valid: :dv, i0: :di0, q0: :dq0, i1: :di1, q1: :dq1, emin: :emin,
    detect: :r_detect, det_count: :r_det_count, done: :r_done, ts_off: :r_ts_off, dphi: :r_dphi,
    sync_td: :r_sync_td, sync_count: :r_sync_count, drop_count: :r_drop_count, preempt_count: :r_preempt, overrun: :r_overrun,
    scale: :r_scale, noise: :r_noise, e_valid: :r_e_valid, e_i: :r_e_i, e_q: :r_e_q, e_g: :r_e_g,
    e_d: :r_e_d, e_j: :r_e_j, e_last: :r_e_last, e_theta: :r_e_theta,
    sig_done: :r_sig_done, sig_ok: :r_sig_ok, sig_discard: :r_sig_discard, nsym_total: :r_nsym_total,
    sig_bits: :r_sig_bits, f_mcs: :r_f_mcs, f_length: :r_f_length, f_aggr: :r_f_aggr, f_ndata: :r_f_ndata,
    b_valid: :r_b_valid, b_byte: :r_b_byte, b_last: :r_b_last, b_len: :r_b_len,
    v_overflow: :r_v_overflow, d_early: :r_d_early

  instance :txp, MimoHalow.Hw.Tx.TxPhy,
    clk: :data_clk, start: :t_start, seed: :t_par_seed, rate: :t_par_rate, mod: :t_par_mod, nsym: :t_par_nsym,
    nbits: :t_len_nbits, len: :t_len_len, sig: :t_sig, b_data: :t_bdata, tick: :tick,
    b_addr: :t_baddr, o_valid: :t_ov, o_i: :t_oi, o_q: :t_oq, busy: :t_busy, done: :t_done, under: :t_under
end

