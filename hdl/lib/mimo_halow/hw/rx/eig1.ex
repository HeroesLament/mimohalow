defmodule MimoHalow.Hw.Rx.Eig1 do
  @moduledoc """
  Two-chain S1G 2 MHz receiver up to phase-corrected points, the receive
  side of `:siso`, `:mrc_1x2` and `:eigen_1ss`:

      chain 0: StfDetector -> LtfSync (sync) -> SymFeed -> Fft64 --+
      chain 1: StfDetector (DC removal only) -> SymFeed -> Fft64 --+-> BinMerge
               -> MrcCombiner -> Cpe -> S1gSigDec (nsym back to both SymFeeds)

  The OcuSync blocks are reused as is: S1G_SHORT's STF / LTF1 have the
  11a L-STF / L-LTF layout. Both `SymFeed`s take chain 0's sync, so the two
  FFTs run in lock step. Samples (12-bit, 2 MS/s) at least 8 cycles apart
  (BinMerge replays 128 bins per 64-sample window at 4 cycles per bin); 16
  at the 32 MHz clock.

  `S1gSigDec` closes the loop: on `sig_done` both SymFeeds take
  `nsym_total` (LTF x2 + SIG x2 + DATA, or 4 on a discard), so the feeder
  stops after the PPDU and is free for the next one.
  """

  use Hw.Component

  clock :clk, freq: 32.0

  input :enable, 1
  input :valid, 1
  input :i0, 12
  input :q0, 12
  input :i1, 12
  input :q1, 12
  input :emin, 32

  output :detect, 1
  output :det_count, 16
  output :done, 1
  output :ts_off, 6
  output :dphi, 24
  output :sync_td, 32
  output :sync_count, 16
  output :drop_count, 16
  output :overrun, 8
  output :scale, 4
  output :noise, 42
  output :e_valid, 1
  output :e_i, 27
  output :e_q, 27
  output :e_g, 21
  output :e_d, 6
  output :e_j, 11
  output :e_last, 1
  output :e_theta, 16
  output :sig_done, 1
  output :sig_ok, 1
  output :sig_discard, 1
  output :nsym_total, 11
  output :sig_bits, 48
  output :f_mcs, 4
  output :f_length, 9
  output :f_aggr, 1
  output :f_ndata, 11

  # chain 0 detector / sync
  wire :det_pr, 32
  wire :det_pi, 32
  wire :det_r, 32
  wire :pass, 1
  wire :yv0, 1
  wire :yi0, 13
  wire :yq0, 13
  wire :sync_busy, 1
  wire :theta, 16
  wire :theta2, 16

  # chain 1 conditioning (its detector outputs unused)
  wire :det1, 1
  wire :det1_pr, 32
  wire :det1_pi, 32
  wire :det1_r, 32
  wire :det1_count, 16
  wire :pass1, 1
  wire :yv1, 1
  wire :yi1, 13
  wire :yq1, 13

  # feeders / FFTs
  wire :zv0, 1
  wire :zi0, 18
  wire :zq0, 18
  wire :zs0, 11
  wire :zf0, 1
  wire :fb0, 1
  wire :zv1, 1
  wire :zi1, 18
  wire :zq1, 18
  wire :zs1, 11
  wire :zf1, 1
  wire :fb1, 1
  wire :drop1, 16
  wire :ztag0, 12
  wire :ztag1, 12
  wire :fv0, 1
  wire :fi0, 26
  wire :fq0, 26
  wire :fp0, 6
  wire :fbin0, 6
  wire :ft0, 12
  wire :fv1, 1
  wire :fi1, 26
  wire :fq1, 26
  wire :fp1, 6
  wire :fbin1, 6
  wire :ft1, 12

  # merged bins -> combiner -> cpe
  wire :mv, 1
  wire :mi, 26
  wire :mq, 26
  wire :mbin, 6
  wire :mch, 1
  wire :mtag, 12
  wire :cv, 1
  wire :ci, 26
  wire :cq, 26
  wire :cg, 21
  wire :cd, 6
  wire :cj, 11
  wire :cst, 1
  wire :clast, 1
  wire :cpil, 1
  wire :pv, 1
  wire :pq, 27
  wire :pd, 6
  wire :pj, 11
  wire :sq, 5
  wire :fsm, 1
  wire :fid, 9
  wire :fnsts, 2

  comb do
    ztag0 = {zf0, zs0}
    ztag1 = {zf1, zs1}
    e_valid = pv
    e_q = pq
    e_d = pd
    e_j = pj
  end

  instance :stf0, Hw.StfDetector,
    clk: :clk, enable: :enable, valid: :valid, i: :i0, q: :q0, emin: :emin,
    detect: :detect, det_pr: :det_pr, det_pi: :det_pi, det_r: :det_r, det_count: :det_count,
    pass: :pass, y_valid: :yv0, y_i: :yi0, y_q: :yq0

  instance :stf1, Hw.StfDetector,
    clk: :clk, enable: :enable, valid: :valid, i: :i1, q: :q1, emin: :emin,
    detect: :det1, det_pr: :det1_pr, det_pi: :det1_pi, det_r: :det1_r, det_count: :det1_count,
    pass: :pass1, y_valid: :yv1, y_i: :yi1, y_q: :yq1

  instance :ltf, Hw.LtfSync,
    clk: :clk, enable: :enable, y_valid: :yv0, y_i: :yi0, y_q: :yq0,
    det: :detect, det_pr: :det_pr, det_pi: :det_pi,
    done: :done, busy: :sync_busy, ts_off: :ts_off, theta: :theta, theta2: :theta2, dphi: :dphi,
    sync_td: :sync_td, sync_count: :sync_count

  instance :feed0, Hw.SymFeed,
    clk: :clk, enable: :enable, y_valid: :yv0, y_i: :yi0, y_q: :yq0,
    sync_done: :done, sync_td: :sync_td, ts_off: :ts_off, dphi: :dphi, set_nsym: :sig_done, nsym: :nsym_total,
    z_valid: :zv0, z_i: :zi0, z_q: :zq0, z_sym: :zs0, z_flush: :zf0, busy: :fb0, drop_count: :drop_count

  instance :feed1, Hw.SymFeed,
    clk: :clk, enable: :enable, y_valid: :yv1, y_i: :yi1, y_q: :yq1,
    sync_done: :done, sync_td: :sync_td, ts_off: :ts_off, dphi: :dphi, set_nsym: :sig_done, nsym: :nsym_total,
    z_valid: :zv1, z_i: :zi1, z_q: :zq1, z_sym: :zs1, z_flush: :zf1, busy: :fb1, drop_count: :drop1

  instance :fft0, Hw.Fft64,
    clk: :clk, enable: :enable, in_valid: :zv0, in_i: :zi0, in_q: :zq0, in_tag: :ztag0,
    out_valid: :fv0, out_i: :fi0, out_q: :fq0, out_pos: :fp0, out_bin: :fbin0, out_tag: :ft0

  instance :fft1, Hw.Fft64,
    clk: :clk, enable: :enable, in_valid: :zv1, in_i: :zi1, in_q: :zq1, in_tag: :ztag1,
    out_valid: :fv1, out_i: :fi1, out_q: :fq1, out_pos: :fp1, out_bin: :fbin1, out_tag: :ft1

  instance :merge, MimoHalow.Hw.Rx.BinMerge,
    clk: :clk, enable: :enable,
    a_valid: :fv0, a_i: :fi0, a_q: :fq0, a_pos: :fp0, a_tag: :ft0,
    b_valid: :fv1, b_i: :fi1, b_q: :fq1, b_pos: :fp1,
    o_valid: :mv, o_i: :mi, o_q: :mq, o_bin: :mbin, o_chain: :mch, o_tag: :mtag, overrun: :overrun

  instance :comb, MimoHalow.Hw.Rx.MrcCombiner,
    clk: :clk, enable: :enable, in_valid: :mv, in_i: :mi, in_q: :mq, in_bin: :mbin, in_chain: :mch, in_tag: :mtag,
    e_valid: :cv, e_i: :ci, e_q: :cq, e_g: :cg, e_d: :cd, e_j: :cj, e_stream: :cst, e_last: :clast,
    e_pilot: :cpil, scale: :scale, noise: :noise

  instance :cpe, MimoHalow.Hw.Rx.Cpe,
    clk: :clk, enable: :enable, in_valid: :cv, in_i: :ci, in_q: :cq, in_g: :cg, in_d: :cd, in_j: :cj,
    in_last: :clast, in_pilot: :cpil,
    e_valid: :pv, e_i: :e_i, e_q: :pq, e_g: :e_g, e_d: :pd, e_j: :pj, e_last: :e_last, e_theta: :e_theta

  instance :sigdec, MimoHalow.Hw.Rx.S1gSigDec,
    clk: :clk, enable: :enable, e_valid: :pv, e_q: :pq, e_d: :pd, e_j: :pj,
    sig_done: :sig_done, sig_ok: :sig_ok, discard: :sig_discard, nsym_total: :nsym_total,
    sig_bits: :sig_bits, q: :sq, f_mcs: :f_mcs, f_length: :f_length, f_aggr: :f_aggr,
    f_smoothing: :fsm, f_id: :fid, f_nsts: :fnsts, f_ndata: :f_ndata
end
