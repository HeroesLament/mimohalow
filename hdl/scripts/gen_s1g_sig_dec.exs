# Generates lib/mimo_halow/hw/rx/s1g_sig_dec.ex (MimoHalow.Hw.Rx.S1gSigDec),
# the S1G 2 MHz SIG decoder after Hw.Rx.Cpe. Derived from openocusync's
# gen_sig_dec.exs: same collect / soft scale / folded Viterbi / traceback
# engine, with the S1G SIG (2 QBPSK symbols on the 48 legacy tones, 16 x 3
# interleaver, 48 information bits, CRC-4) and field layout.
#
#   mix run scripts/gen_s1g_sig_dec.exs
#
# Spec: MimoHalow.Model.S1g (Params, Coding, Ppdu.parse_sig) and
# test/s1g_sig_dec_test.exs.
import Bitwise
alias MimoHalow.Model.S1g.{Coding, Params}

# Data index d (Cpe order, Params.data(2)) -> SIG coded-bit position c within
# the symbol: tone s = position in Params.sig_data(2) carries the coded bit the
# interleaver sent there, c = perm^-1(s).
perm = Coding.perm(Params.interleaver(:sig2, 1), 1, 48)
inv = perm |> Enum.with_index() |> Map.new(fn {pos, c} -> {pos, c} end)
spos = Params.sig_data(2) |> Enum.with_index() |> Map.new()
dmap = Params.data(2) |> Enum.with_index() |> Enum.flat_map(fn {k, d} -> if Map.has_key?(spos, k), do: [{d, inv[spos[k]]}], else: [] end)
crow_arms = Enum.flat_map(dmap, fn {d, c} -> ["      #{d} ->", "        cv = 1", "        cpos = #{c}"] end)
ndbps = for m <- 0..15, do: (if m > 10, do: 0, else: (case Params.rate(2, m) do {:ok, r} -> r.ndbps; _ -> 0 end))
ndbps_arms = ndbps |> Enum.with_index() |> Enum.flat_map(fn {v, m} -> ["      #{m} ->", "        ndb = #{v}"] end)
# CRC-4 over SIG bits 0..37 (x^4 + x + 1, init 1111), unrolled. Register
# bits 3..0 = model cells r0..r3: t = x ^ r0, next = {r1, r2, r3 ^ t, t}.
crc4_s1g =
  Enum.map_join(0..37, "\n", fn i ->
    prev = if i == 0, do: "c4init", else: "c4_#{i - 1}"
    "    c4t_#{i} = bxor(bits[#{i}..#{i}], #{prev}[3..3])\n" <>
      "    c4_#{i} = bxor({#{prev}[2..0], zero16[0..0]}, {zero16[1..0], c4t_#{i}, c4t_#{i}})"
  end)
crc4_decls = Enum.flat_map(0..37, fn i -> ["  wire :c4t_#{i}, 1", "  wire :c4_#{i}, 4"] end)

ga = 0b1011011
gb = 0b1111001
parity = fn x -> x |> Integer.digits(2) |> Enum.sum() |> rem(2) end
outs = fn reg -> {parity.(reg &&& ga), parity.(reg &&& gb)} end

ashr = fn
  sig, _w, 0 -> sig
  sig, w, i when i >= w -> "replicate(#{sig}[#{w - 1}..#{w - 1}], #{w})"
  sig, w, i -> "{replicate(#{sig}[#{w - 1}..#{w - 1}], #{i}), #{sig}[#{w - 1}..#{i}]}"
end

# Branch metric wire for coded pair (a, b): +s for a 1, -s for a 0.
bm = fn {a, b} -> "bm#{a}#{b}" end

# Folded ACS: cycle g (1..8 of a step, group gg = g - 1) runs butterflies
# j = 4 gg .. 4 gg + 3: old metrics 8 gg .. 8 gg + 7 from the current bank,
# new metrics j (input bit 0) and j + 32 (bit 1) to the other bank. Each new
# metric is the same arithmetic as the parallel ACS, so the decisions match.
init = fn st -> if st == 0, do: 0, else: 49152 end
pm_decls =
  Enum.flat_map(0..63, fn st -> ["  wire :pa#{st}, 16, init: #{init.(st)}"] ++ if(rem(div(st, 4), 8) == 7, do: [], else: ["  wire :pb#{st}, 16, init: 0", "  wire :d#{st}, 1, init: 0"]) end) ++
    ["  wire :c, 4, init: 0", "  wire :gg, 3", "  wire :sar, 16, init: 0", "  wire :sbr, 16, init: 0", "  wire :dword, 64"] ++
    Enum.map(0..7, &"  wire :rd#{&1}, 16")

acs_decls =
  Enum.flat_map(0..3, fn i ->
    Enum.flat_map(["l", "h"], fn h ->
      ["  wire :b#{i}#{h}0, 16", "  wire :b#{i}#{h}1, 16", "  wire :m0#{h}#{i}, 16", "  wire :m1#{h}#{i}, 16",
       "  wire :md#{h}#{i}, 16", "  wire :od#{h}#{i}, 1", "  wire :nm#{h}#{i}, 16"]
    end)
  end)

rd_arms =
  Enum.flat_map(0..7, fn k ->
    ["    rd#{k} = pa#{k}", "    case gg do"] ++
      Enum.flat_map(0..7, fn g -> ["      #{g} ->", "        rd#{k} = pa#{8 * g + k}"] end) ++ ["    end"]
  end)

bm_arms =
  ["    case gg do"] ++
    Enum.flat_map(0..7, fn g ->
      ["      #{g} ->"] ++
        Enum.flat_map(0..3, fn i ->
          s0 = 8 * g + 2 * i
          s1 = s0 + 1
          ["        b#{i}l0 = #{bm.(outs.(s0))}", "        b#{i}l1 = #{bm.(outs.(s1))}",
           "        b#{i}h0 = #{bm.(outs.(64 ||| s0))}", "        b#{i}h1 = #{bm.(outs.(64 ||| s1))}"]
        end)
    end) ++ ["    end"]

acs_comb =
  ["    gg = c[2..0] - 1"] ++ rd_arms ++ bm_arms ++
    Enum.flat_map(0..3, fn i ->
      Enum.flat_map(["l", "h"], fn h ->
        ["    m0#{h}#{i} = rd#{2 * i} + b#{i}#{h}0", "    m1#{h}#{i} = rd#{2 * i + 1} + b#{i}#{h}1",
         "    md#{h}#{i} = m0#{h}#{i} - m1#{h}#{i}", "    od#{h}#{i} = md#{h}#{i}[15..15]",
         "    nm#{h}#{i} = if od#{h}#{i} == 1 do m1#{h}#{i} else m0#{h}#{i} end"]
      end)
    end) ++
    # Decision word of the step: groups 0..6 from the d registers, group 7 (this cycle) live.
    ["    dword = {" <>
       Enum.map_join(63..0//-1, ", ", fn st ->
         if rem(div(st, 4), 8) == 7, do: "od#{if st >= 32, do: "h", else: "l"}#{rem(st, 4)}", else: "d#{st}"
       end) <> "}"]

write_arms = fn bank ->
  ["          case gg do"] ++
    Enum.flat_map(0..7, fn g ->
      ["            #{g} ->"] ++
        Enum.flat_map(0..3, fn i ->
          if(g < 7,
            do: ["              #{bank}#{4 * g + i} = nml#{i}", "              #{bank}#{32 + 4 * g + i} = nmh#{i}",
                 "              d#{4 * g + i} = odl#{i}", "              d#{32 + 4 * g + i} = odh#{i}"],
            else: [])
        end)
    end) ++ ["          end"]
end

acs_step =
  ["      # Viterbi, 9 cycles per step: c = 0 latches the soft pair of step ta",
   "      # (its read was issued during the previous step), c = 1..8 run the",
   "      # eight butterfly groups; the decision word goes out on c = 8.",
   "      if st == 1 and ph == 1 do",
   "        if c == 0 do",
   "          sar = sa_c",
   "          sbr = sb_c",
   "          c = 1",
   "        else",
   "          # New metrics of groups 0..6 go to bank B; on c = 8 bank A takes"] ++ write_arms.("pb") ++ [
   "          # them all at once (copy at the step end; group 7 straight from the ACS),",
   "          # so the reads never need a bank select.",
   "          if c == 8 do"] ++
    Enum.flat_map(0..63, fn st ->
      if rem(div(st, 4), 8) == 7,
        do: ["            pa#{st} = nm#{if st >= 32, do: "h", else: "l"}#{rem(st, 4)}"],
        else: ["            pa#{st} = pb#{st}"]
    end) ++ [
   "            dmem[ta] = dword",
   "            c = 0",
   "            if ta == 47 do",
   "              st = 2",
   "              ph = 0",
   "              ns = 0",
   "              t = 47",
   "            else",
   "              ta = t",
   "              t = t + 1",
   "            end",
   "          else",
   "            c = c + 1",
   "          end",
   "        end",
   "      end"]

pm_init = Enum.map(0..63, fn st -> "        pa#{st} = #{init.(st)}" end) ++ ["        c = 0"]

# Soft: sat to +-31 of (e >>> q), q 0..24.
soft_arms = fn out, inp -> Enum.flat_map(0..31, fn n -> ["      #{n} ->", "        #{out} = #{ashr.(inp, 26, n)}"] end) end

# q = max(0, bitlen(sum >> 7) - 3): bit b of sum (b >= 9) gives q = b - 9.
qenc = Enum.reduce(9..33, "0", fn b, acc -> "if sum[#{b}..#{b}] == 1 do #{b - 9} else (#{acc}) end" end)

decsel_arms = Enum.flat_map(0..63, fn n -> ["      #{n} ->", "        tb_odd = drd[#{n}..#{n}]"] end)

src = ~S'''
defmodule MimoHalow.Hw.Rx.S1gSigDec do
  @moduledoc """
  S1G 2 MHz SIG decoder: after `MimoHalow.Hw.Rx.Cpe`, for symbols 0..1.
  GENERATED by `scripts/gen_s1g_sig_dec.exs` (derived from openocusync's
  `gen_sig_dec.exs`); edit the generator, not this file.

  1. Collect: `e_q` (Im of the phase-corrected point: QBPSK, positive = 1)
     of symbols `e_j` 0..1 on the 48 SIG tones, de-interleaved by a ROM
     (data index -> coded bit `48 j + c`) into even / odd pair memories,
     with `sum |x|` (x = e_q >> 1, 26-bit).
  2. `q = max(0, bitlen(sum >> 7) - 3)`; soft `s = clamp(x >> q, -31, 31)`.
  3. Viterbi, K = 7, 133 / 171, 64 states, 48 steps over 96 soft bits
     (OcuSync's folded engine: eight ACS per cycle, 9 cycles per step),
     traceback from state 0.
  4. CRC-4 over bits 0..37; fields per `S1g.Ppdu.parse_sig/2`.
  5. `sig_done` with `sig_ok`, the fields, `discard` (CRC, NSTS != 1,
     STBC, LDPC, MCS > 8) and `nsym_total = discard ? 4 : 4 + Ndata` (LTF
     x2, SIG x2, DATA) for `Hw.SymFeed`'s `set_nsym`; Ndata = LENGTH when
     aggregated, else ceil((14 + 8 LENGTH) / Ndbps(MCS)), a serial
     subtraction.

  Contains written memories: verified under iverilog only.
  """

  use Hw.Component

  clock :clk, freq: 32.0

  input :enable, 1
  input :e_valid, 1
  input :e_q, 27
  input :e_d, 6
  input :e_j, 11

  output :sig_done, 1
  output :sig_ok, 1
  output :discard, 1
  output :nsym_total, 11
  output :sig_bits, 48
  output :q, 5
  output :f_mcs, 4
  output :f_length, 9
  output :f_aggr, 1
  output :f_smoothing, 1
  output :f_id, 9
  output :f_nsts, 2
  output :f_ndata, 11

  memory :mem_e, width: 26, depth: 128, sync_read: :clk
  memory :mem_o, width: 26, depth: 128, sync_read: :clk
  memory :dmem, width: 64, depth: 128, sync_read: :clk

  wire :zero26, 26
  wire :zero16, 16
  wire :c4init, 4

  # --- collect ------------------------------------------------------------------
  wire :x, 26
  wire :cv, 1
  wire :cpos, 6
  wire :n, 7
  wire :e_abs, 26
  wire :sum, 34, init: 0
  wire :in_sig, 1

  # --- control --------------------------------------------------------------------
  wire :st, 3, init: 0
  wire :ph, 2, init: 0
  wire :t, 7, init: 0
  wire :qq, 5, init: 0
  wire :q_c, 5
  wire :rev, 26
  wire :rod, 26
  wire :shev, 26
  wire :shod, 26
  wire :ta, 7, init: 0
  wire :sa_c, 16
  wire :sb_c, 16
  wire :bm11, 16
  wire :bm10, 16
  wire :bm01, 16
  wire :bm00, 16
  wire :drd, 64
  wire :ns, 6, init: 0
  wire :tb_odd, 1
  wire :bits, 48, init: 0
  wire :crc_ok, 1
  wire :disc_c, 1
  wire :ndb, 9
  wire :num, 13, init: 0
  wire :nd, 11, init: 0
  wire :done_q, 1, init: 0
  wire :ok_q, 1, init: 0
  wire :disc_q, 1, init: 0
  wire :nt_q, 11, init: 0
  wire :nd_q, 11, init: 0
@@CRC4_DECLS@@
@@PM_DECLS@@
@@ACS_DECLS@@

  comb do
    zero26 = 0
    zero16 = 0
    c4init = 15

    x = e_q[26..1]
    cv = 0
    cpos = 0
    case e_d do
@@CROW@@
    end
    in_sig = if e_valid == 1 and e_j < 2 and cv == 1 do 1 else 0 end
    n = if e_j == 1 do {zero16[0..0], cpos} + 48 else {zero16[0..0], cpos} end
    e_abs = if x[25..25] == 1 do zero26 - x else x end

    q_c = @@QENC@@

    rev = mem_e[t]
    rod = mem_o[t]
    shev = rev
    case qq do
@@SOFT_EV@@
    end
    shod = rod
    case qq do
@@SOFT_OD@@
    end
    sa_c = if shev[25..25] == 0 and shev[24..5] != 0 do 31 else (if shev[25..25] == 1 and (shev[24..5] != 1048575 or shev[4..0] == 0) do 65505 else {replicate(shev[25..25], 10), shev[5..0]} end) end
    sb_c = if shod[25..25] == 0 and shod[24..5] != 0 do 31 else (if shod[25..25] == 1 and (shod[24..5] != 1048575 or shod[4..0] == 0) do 65505 else {replicate(shod[25..25], 10), shod[5..0]} end) end

    bm11 = sar + sbr
    bm10 = sar - sbr
    bm01 = sbr - sar
    bm00 = zero16 - sar - sbr
@@ACS_COMB@@

    drd = dmem[t]
    tb_odd = 0
    case ns do
@@DECSEL@@
    end

@@CRC4@@
    crc_ok = if bits[38..38] == bnot(c4_37[3..3]) and bits[39..39] == bnot(c4_37[2..2]) and bits[40..40] == bnot(c4_37[1..1]) and bits[41..41] == bnot(c4_37[0..0]) do 1 else 0 end
    ndb = 0
    case bits[22..19] do
@@NDBPS@@
    end
    disc_c = if crc_ok == 0 or bits[6..5] != 0 or bits[1..1] != 0 or bits[17..17] != 0 or bits[22..19] > 8 do 1 else 0 end

    sig_done = done_q
    sig_ok = ok_q
    discard = disc_q
    nsym_total = nt_q
    sig_bits = bits
    q = qq
    f_mcs = bits[22..19]
    f_length = bits[33..25]
    f_aggr = bits[24..24]
    f_smoothing = bits[23..23]
    f_id = bits[15..7]
    f_nsts = bits[6..5]
    f_ndata = nd_q
  end

  # st: 0 collect, 1 Viterbi, 2 traceback, 3 Ndata, 4 decide.
  on :clk do
    done_q = 0
    if enable == 0 do
      st = 0
      sum = 0
    else
      if st == 0 and in_sig == 1 do
        if n[0..0] == 0 do
          mem_e[{zero16[0..0], n[6..1]}] = x
        else
          mem_o[{zero16[0..0], n[6..1]}] = x
        end
        if e_j == 0 and e_d == @@FIRSTD@@ do
          sum = {zero16[7..0], e_abs}
        else
          sum = sum + {zero16[7..0], e_abs}
        end
      end
      if st == 0 and e_valid == 1 and e_j == 1 and e_d == 51 do
        st = 1
        ph = 0
        t = 0
      end
      if st == 1 and ph == 0 do
        qq = q_c
        ta = 0
        t = 1
        ph = 1
      end
@@ACS_STEP@@
      if st == 1 and ph == 0 do
@@PM_INIT@@
      end
      if st == 2 and ph == 0 do
        t = 46
        ph = 1
      end
      if st == 2 and ph == 1 do
        bits = {bits[46..0], ns[5..5]}
        ns = {ns[4..0], tb_odd}
        if ta == 0 do
          st = 3
          ph = 0
        else
          ta = ta - 1
          t = t - 1
        end
      end
      # Ndata: LENGTH when aggregated, else ceil((14 + 8 LENGTH) / Ndbps), serially.
      if st == 3 do
        if ph == 0 do
          num = {zero16[0..0], bits[33..25], zero16[2..0]} + 14
          nd = 0
          ph = 1
        else
          if bits[24..24] == 1 or disc_c == 1 or ndb == 0 do
            nd = {zero16[1..0], bits[33..25]}
            st = 4
          else
            if num == 0 or num[12..12] == 1 do
              st = 4
            else
              num = num - {zero16[3..0], ndb}
              nd = nd + 1
            end
          end
        end
      end
      if st == 4 do
        done_q = 1
        ok_q = crc_ok
        disc_q = disc_c
        nd_q = nd
        nt_q = if disc_c == 1 do 4 else nd + 4 end
        st = 0
      end
    end
  end
end
'''

src =
  src
  |> String.replace("@@PM_DECLS@@", Enum.join(pm_decls, "\n"))
  |> String.replace("@@ACS_DECLS@@", Enum.join(acs_decls, "\n"))
  |> String.replace("@@QENC@@", qenc)
  |> String.replace("@@SOFT_EV@@", Enum.join(soft_arms.("shev", "rev"), "\n"))
  |> String.replace("@@SOFT_OD@@", Enum.join(soft_arms.("shod", "rod"), "\n"))
  |> String.replace("@@ACS_COMB@@", Enum.join(acs_comb, "\n"))
  |> String.replace("@@DECSEL@@", Enum.join(decsel_arms, "\n"))
  |> String.replace("@@PM_INIT@@", Enum.join(pm_init, "\n"))
  |> String.replace("@@ACS_STEP@@", Enum.join(acs_step, "\n"))
  |> String.replace("@@CRC4@@", crc4_s1g)
  |> String.replace("@@CRC4_DECLS@@", Enum.join(crc4_decls, "\n"))
  |> String.replace("@@CROW@@", Enum.join(crow_arms, "\n"))
  |> String.replace("@@NDBPS@@", Enum.join(ndbps_arms, "\n"))
  |> String.replace("@@FIRSTD@@", Integer.to_string(dmap |> Enum.map(&elem(&1, 0)) |> Enum.min()))

out = Path.expand("../lib/mimo_halow/hw/rx/s1g_sig_dec.ex", __DIR__)
File.mkdir_p!(Path.dirname(out))
File.write!(out, src)
IO.puts("wrote #{out} (#{src |> String.split("\n") |> length()} lines)")
