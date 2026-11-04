defmodule MimoHalow.Hw.Rx.DcBlock do
  @moduledoc """
  DC blocker for the four 12-bit sample components ahead of Decim4; twin of
  `MimoHalow.Model.Fixed.DcBlock`.

  Per component a signed 24-bit accumulator holds the DC estimate times
  2^12: on each valid sample `d = acc[23:12]`, `y = sat12(x - d)`,
  `acc += x - d`. Time constant 4096 samples (512 us at 8 MS/s), corner
  ~310 Hz. `bypass` outputs x unchanged (the estimate keeps running). One
  cycle of latency; `o_valid` follows `valid`.
  """
  use Hw.Component

  clock(:clk, freq: 32.0)

  input(:enable, 1)
  input(:bypass, 1)
  input(:valid, 1)
  input(:i0, 12)
  input(:q0, 12)
  input(:i1, 12)
  input(:q1, 12)

  output(:o_valid, 1)
  output(:o_i0, 12)
  output(:o_q0, 12)
  output(:o_i1, 12)
  output(:o_q1, 12)

  wire(:a_i0, 24, init: 0)
  wire(:a_q0, 24, init: 0)
  wire(:a_i1, 24, init: 0)
  wire(:a_q1, 24, init: 0)
  wire(:y_i0, 13)
  wire(:y_q0, 13)
  wire(:y_i1, 13)
  wire(:y_q1, 13)
  wire(:s_i0, 12)
  wire(:s_q0, 12)
  wire(:s_i1, 12)
  wire(:s_q1, 12)
  wire(:r_i0, 12, init: 0)
  wire(:r_q0, 12, init: 0)
  wire(:r_i1, 12, init: 0)
  wire(:r_q1, 12, init: 0)
  wire(:ov, 1, init: 0)

  comb do
    y_i0 = {i0[11..11], i0} - {a_i0[23..23], a_i0[23..12]}
    y_q0 = {q0[11..11], q0} - {a_q0[23..23], a_q0[23..12]}
    y_i1 = {i1[11..11], i1} - {a_i1[23..23], a_i1[23..12]}
    y_q1 = {q1[11..11], q1} - {a_q1[23..23], a_q1[23..12]}

    # Saturate: a full if/else (a comb `if` without `else` emits 0, not
    # the earlier assignment).
    s_i0 =
      if y_i0[12..12] != y_i0[11..11] do
        if y_i0[12..12] == 1 do
          2048
        else
          2047
        end
      else
        y_i0[11..0]
      end

    s_q0 =
      if y_q0[12..12] != y_q0[11..11] do
        if y_q0[12..12] == 1 do
          2048
        else
          2047
        end
      else
        y_q0[11..0]
      end

    s_i1 =
      if y_i1[12..12] != y_i1[11..11] do
        if y_i1[12..12] == 1 do
          2048
        else
          2047
        end
      else
        y_i1[11..0]
      end

    s_q1 =
      if y_q1[12..12] != y_q1[11..11] do
        if y_q1[12..12] == 1 do
          2048
        else
          2047
        end
      else
        y_q1[11..0]
      end

    o_valid = ov
    o_i0 = r_i0
    o_q0 = r_q0
    o_i1 = r_i1
    o_q1 = r_q1
  end

  on :clk do
    ov = 0

    if enable == 1 and valid == 1 do
      a_i0 = a_i0 + {replicate(i0[11..11], 12), i0} - {replicate(a_i0[23..23], 12), a_i0[23..12]}
      a_q0 = a_q0 + {replicate(q0[11..11], 12), q0} - {replicate(a_q0[23..23], 12), a_q0[23..12]}
      a_i1 = a_i1 + {replicate(i1[11..11], 12), i1} - {replicate(a_i1[23..23], 12), a_i1[23..12]}
      a_q1 = a_q1 + {replicate(q1[11..11], 12), q1} - {replicate(a_q1[23..23], 12), a_q1[23..12]}

      r_i0 =
        if bypass == 1 do
          i0
        else
          s_i0
        end

      r_q0 =
        if bypass == 1 do
          q0
        else
          s_q0
        end

      r_i1 =
        if bypass == 1 do
          i1
        else
          s_i1
        end

      r_q1 =
        if bypass == 1 do
          q1
        else
          s_q1
        end

      ov = 1
    end
  end
end
