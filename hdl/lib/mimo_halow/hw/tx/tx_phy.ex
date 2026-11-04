defmodule MimoHalow.Hw.Tx.TxPhy do
  @moduledoc """
  S1G 2 MHz single-stream transmit PHY on DATA_CLK: PSDU bytes from a
  24-bit word buffer -> `Tx.Encoder` -> `Tx.Mapper` -> `Tx.Ofdm` ->
  `Tx.Interp4` -> 12-bit TX port samples at 8 MS/s, one per `tick`.

  The host supplies what is cheap in software and costly in fabric: the 96
  interleaved SIG coded bits (`sig`, as `Tx.Ofdm`), `nsym`, `nbits` = nsym *
  Ndbps, `rate` (0 1/2, 1 2/3, 2 3/4, 3 5/6), `mod` (0 BPSK .. 4 256-QAM),
  `seed` (scrambler, nonzero) and `len` (PSDU bytes, FCS included). All are
  sampled by `start` and must hold until `done`.

  Buffer: word w holds PSDU bytes 3w, 3w + 1, 3w + 2 in [7:0], [15:8],
  [23:16]. `b_addr` is read through a synchronous port (`b_data` one cycle
  later); the buffer belongs to the host side and must not change while
  `busy`.

  `tick` is the TX port's sample request. A tick that finds a sample takes
  it (`o_valid`); one that finds none after the first sample is an underrun
  (`under`). `done` pulses with the final sample; `busy` runs from `start`
  to `done`.
  """
  use Hw.Component

  clock :clk, freq: 32.0

  input :start, 1
  input :seed, 7
  input :rate, 2
  input :mod, 3
  input :nsym, 10
  input :nbits, 16
  input :len, 10
  input :sig, 96
  input :b_data, 24
  input :tick, 1

  output :b_addr, 10
  output :o_valid, 1
  output :o_i, 12
  output :o_q, 12
  output :busy, 1
  output :done, 1
  output :under, 1

  # byte feeder
  wire :ra, 10, init: 0
  wire :bw, 24, init: 0
  wire :bv, 1, init: 0
  wire :bi, 2, init: 0
  wire :pend, 1, init: 0
  wire :run, 1, init: 0
  wire :seen, 1, init: 0
  wire :in_byte, 8
  wire :take, 1
  wire :fetch, 1
  wire :got, 1

  # encoder -> mapper
  wire :e_in_ready, 1
  wire :e_o_valid, 1
  wire :e_o_bit, 1
  wire :e_busy, 1
  wire :e_done, 1

  # mapper -> ofdm
  wire :m_i_ready, 1
  wire :m_o_valid, 1
  wire :m_o_i, 5
  wire :m_o_q, 5
  wire :m_o_bin, 6
  wire :m_o_last, 1

  # ofdm -> interp
  wire :f_p_ready, 1
  wire :f_o_valid, 1
  wire :f_o_i, 16
  wire :f_o_q, 16
  wire :f_o_last, 1
  wire :f_busy, 1

  # interp -> port
  wire :x_i_ready, 1
  wire :x_o_valid, 1
  wire :x_o_i, 12
  wire :x_o_q, 12
  wire :x_o_last, 1

  comb do
    in_byte = if bi == 0 do bw[7..0] else (if bi == 1 do bw[15..8] else bw[23..16] end) end
    take = band(bv, e_in_ready)
    fetch = if run == 1 and bv == 0 and pend == 0 do 1 else 0 end
    b_addr = ra

    got = band(x_o_valid, tick)
    o_valid = got
    o_i = x_o_i
    o_q = x_o_q
    done = band(got, x_o_last)
    under = if run == 1 and seen == 1 and tick == 1 and x_o_valid == 0 do 1 else 0 end
    busy = run
  end

  on :clk do
    if start == 1 do
      ra = 0
      bv = 0
      bi = 0
      pend = 0
      run = 1
      seen = 0
    else
      if fetch == 1 do
        pend = 1
      end
      if pend == 1 do
        bw = b_data
        bv = 1
        bi = 0
        pend = 0
        ra = ra + 1
      end
      if take == 1 do
        if bi == 2 do
          bv = 0
          bi = 0
        else
          bi = bi + 1
        end
      end
      if got == 1 do
        seen = 1
        if x_o_last == 1 do
          run = 0
        end
      end
    end
  end

  instance :enc, MimoHalow.Hw.Tx.Encoder,
    clk: :clk, start: :start, seed: :seed, rate: :rate, nbits: :nbits, len: :len,
    in_valid: :bv, in_byte: :in_byte, o_ready: :m_i_ready,
    in_ready: :e_in_ready, o_valid: :e_o_valid, o_bit: :e_o_bit, busy: :e_busy, done: :e_done

  instance :map, MimoHalow.Hw.Tx.Mapper,
    clk: :clk, start: :start, mod: :mod, i_valid: :e_o_valid, i_bit: :e_o_bit, o_ready: :f_p_ready,
    i_ready: :m_i_ready, o_valid: :m_o_valid, o_i: :m_o_i, o_q: :m_o_q, o_bin: :m_o_bin, o_last: :m_o_last

  instance :ofdm, MimoHalow.Hw.Tx.Ofdm,
    clk: :clk, start: :start, mod: :mod, nsym: :nsym, sig: :sig,
    p_valid: :m_o_valid, p_i: :m_o_i, p_q: :m_o_q, p_bin: :m_o_bin, p_last: :m_o_last, o_ready: :x_i_ready,
    p_ready: :f_p_ready, o_valid: :f_o_valid, o_i: :f_o_i, o_q: :f_o_q, o_last: :f_o_last, busy: :f_busy

  instance :up, MimoHalow.Hw.Tx.Interp4,
    clk: :clk, start: :start, i_valid: :f_o_valid, i_i: :f_o_i, i_q: :f_o_q, i_last: :f_o_last, o_ready: :tick,
    i_ready: :x_i_ready, o_valid: :x_o_valid, o_i: :x_o_i, o_q: :x_o_q, o_last: :x_o_last
end
