# Generates lib/mimo_halow/hw/rx/mrc_combiner.ex (MimoHalow.Hw.Rx.MrcCombiner),
# the receive block shared by the :siso, :mrc_1x2 and :eigen_1ss modes.
# Derived from openocusync's gen_equalizer.exs (same G helpers, same c1..c3
# per-bin pipeline), generalised to two receive chains and without the
# pilot-phase CORDIC (common-phase tracking is a separate, mode-independent
# stage after the combiner).
#
#   mix run scripts/gen_mrc_combiner.exs
#
# Spec: MimoHalow.Model.Fixed.Mrc. Change both together.
#
# Tone plan: S1G 2 MHz (64-point; used +-1..+-28, pilots +-7, +-21, the
# 56-tone S1G/HT-LTF signs), taken from MimoHalow.Model.S1g.Params so the
# RTL ROM and the model share one source.
import Bitwise

defmodule G do
  # Sign-extend `sig` (w bits) to `to` bits.
  def sx(sig, w, to) when to > w, do: "{replicate(#{sig}[#{w - 1}..#{w - 1}], #{to - w}), #{sig}}"
  def sx(sig, w, w), do: sig

  # Arithmetic right shift of a w-bit signal by a constant.
  def ashr(sig, _w, 0), do: sig
  def ashr(sig, w, i) when i >= w, do: "replicate(#{sig}[#{w - 1}..#{w - 1}], #{w})"
  def ashr(sig, w, i), do: "{replicate(#{sig}[#{w - 1}..#{w - 1}], #{i}), #{sig}[#{w - 1}..#{i}]}"

  # out = in >>> sel (arithmetic, w bits), sel a 4-bit signal: {decls, comb}.
  def vshr(out, inp, w, sel) do
    arms = Enum.flat_map(0..15, fn n -> ["      #{n} ->", "        #{out} = #{ashr(inp, w, n)}"] end)
    {["  wire :#{out}, #{w}"], ["    #{out} = #{inp}", "    case #{sel} do"] ++ arms ++ ["    end"]}
  end

  # out = sat(in) to wout bits (in is win bits, two's complement): {decls, comb}.
  def sat(out, inp, win, wout) do
    hb = win - wout + 1
    ones = (1 <<< hb) - 1
    mx = (1 <<< (wout - 1)) - 1
    mn = 1 <<< (wout - 1)

    {["  wire :#{out}, #{wout}", "  wire :#{out}_hi, #{hb}", "  wire :#{out}_mx, #{wout}", "  wire :#{out}_mn, #{wout}"],
     [
       "    #{out}_hi = #{inp}[#{win - 1}..#{wout - 1}]",
       "    #{out}_mx = #{mx}",
       "    #{out}_mn = #{mn}",
       "    #{out} = if #{out}_hi == 0 or #{out}_hi == #{ones} do #{inp}[#{wout - 1}..0] else (if #{inp}[#{win - 1}..#{win - 1}] == 1 do #{out}_mn else #{out}_mx end) end"
     ]}
  end

  # Signed product mod 2^(wa+wb) from an unsigned one (the LtfSync idiom): {decls, comb}.
  def smul(out, a, wa, b, wb) do
    p = wa + wb

    {["  wire :#{out}_u, #{p}", "  wire :#{out}_ka, #{p}", "  wire :#{out}_kb, #{p}", "  wire :#{out}, #{p}"],
     [
       "    #{out}_u = #{a} * #{b}",
       "    #{out}_ka = if #{a}[#{wa - 1}..#{wa - 1}] == 1 do {#{b}, zero#{wa}} else zero#{p} end",
       "    #{out}_kb = if #{b}[#{wb - 1}..#{wb - 1}] == 1 do {#{a}, zero#{wb}} else zero#{p} end",
       "    #{out} = #{out}_u - #{out}_ka - #{out}_kb"
     ]}
  end

  def merge(parts), do: {Enum.flat_map(parts, &elem(&1, 0)), Enum.flat_map(parts, &elem(&1, 1))}
end

# --- tone plan (S1G 2 MHz, see header) -------------------------------------------
alias MimoHalow.Model.S1g.Params
pilot_k = Params.pilots(2)
used_k = Params.used(2)
data_k = Params.data(2)
bin = fn k -> Params.bin(k, 2) end
ltf_k = Params.ltf(2)
bitrev6 = fn i -> for(b <- 0..5, reduce: 0, do: (acc -> acc ||| (i >>> b &&& 1) <<< (5 - b))) end
# Every used tone is emitted: data tones with e_d = data index, pilots with
# e_pilot = 1 and e_d = pilot index. The last used bin in FFT output
# (bit-reversed) order carries e_last.
fft_order = for p <- 0..63, do: bitrev6.(p)
used_bins = MapSet.new(used_k, bin)
last_used_bin = fft_order |> Enum.filter(&MapSet.member?(used_bins, &1)) |> List.last()
dix = data_k |> Enum.with_index() |> Map.new(fn {k, d} -> {bin.(k), d} end)
pix = pilot_k |> Enum.with_index() |> Map.new(fn {k, d} -> {bin.(k), d} end)

rom_arms =
  Enum.flat_map(used_k, fn k ->
    b = bin.(k)

    {pil, idx} = if Map.has_key?(pix, b), do: {1, pix[b]}, else: {0, dix[b]}

    ["      #{b} ->", "        i_used = 1", "        i_sneg = #{if ltf_k[k] < 0, do: 1, else: 0}",
     "        i_data = 1", "        i_pil = #{pil}", "        i_dix = #{idx}",
     "        i_dlast = #{if b == last_used_bin, do: 1, else: 0}"]
  end)

# sh = max(0, bitlen(or_acc) - 16), as a priority chain.
penc = Enum.reduce(16..25, "0", fn b, acc -> "if or_acc[#{b}..#{b}] == 1 do #{b - 15} else (#{acc}) end" end)

datapath =
  G.merge([
    # c1: Yn
    G.vshr("yr_s", "i_r", 26, "sh"),
    G.vshr("yi_s", "i_q", 26, "sh"),
    G.sat("yn_r_c", "yr_s", 26, 25),
    G.sat("yn_i_c", "yi_s", 26, 25),
    # c2, LTF2: Hn, dn
    {["  wire :l1_r, 26", "  wire :l1_i, 26", "  wire :s_r, 28", "  wire :s_i, 28", "  wire :ss_r, 28", "  wire :ss_i, 28", "  wire :dd_r, 28", "  wire :dd_i, 28"],
     [
       "    l1_r = l1rd[51..26]",
       "    l1_i = l1rd[25..0]",
       "    s_r = #{G.sx("l1_r", 26, 28)} + #{G.sx("i_r", 26, 28)}",
       "    s_i = #{G.sx("l1_i", 26, 28)} + #{G.sx("i_q", 26, 28)}",
       "    ss_r = if i_sneg == 1 do zero28 - s_r else s_r end",
       "    ss_i = if i_sneg == 1 do zero28 - s_i else s_i end",
       "    dd_r = #{G.sx("l1_r", 26, 28)} - #{G.sx("i_r", 26, 28)}",
       "    dd_i = #{G.sx("l1_i", 26, 28)} - #{G.sx("i_q", 26, 28)}"
     ]},
    G.vshr("hs_r", "ss_r", 28, "sh"),
    G.vshr("hs_i", "ss_i", 28, "sh"),
    G.sat("hn_r_c", "hs_r", 28, 18),
    G.sat("hn_i_c", "hs_i", 28, 18),
    G.vshr("ds_r", "dd_r", 28, "sh"),
    G.vshr("ds_i", "dd_i", 28, "sh"),
    G.sat("dn_r_c", "ds_r", 28, 18),
    G.sat("dn_i_c", "ds_i", 28, 18),
    # c2, data: D_r = Yn conj(Hn), G_r = |Hn|^2 (this chain)
    {["  wire :h_r, 18", "  wire :h_i, 18"], ["    h_r = hrd[35..18]", "    h_i = hrd[17..0]"]},
    G.smul("p_rr", "yn_r", 25, "h_r", 18),
    G.smul("p_ii", "yn_i", 25, "h_i", 18),
    G.smul("p_ir", "yn_i", 25, "h_r", 18),
    G.smul("p_ri", "yn_r", 25, "h_i", 18),
    G.smul("g_rr", "h_r", 18, "h_r", 18),
    G.smul("g_ii", "h_i", 18, "h_i", 18),
    {["  wire :dr_c, 44", "  wire :di_c, 44", "  wire :g_c, 37"],
     [
       "    dr_c = #{G.sx("p_rr", 43, 44)} + #{G.sx("p_ii", 43, 44)}",
       "    di_c = #{G.sx("p_ir", 43, 44)} - #{G.sx("p_ri", 43, 44)}",
       "    g_c = #{G.sx("g_rr", 36, 37)} + #{G.sx("g_ii", 36, 37)}"
     ]},
    # c3: sat24 D, G >> 16, noise term; chain-1 sums with the stored chain-0 values
    {["  wire :dq_r, 28", "  wire :dq_i, 28", "  wire :gp, 20"],
     ["    dq_r = dr_raw[43..16]", "    dq_i = di_raw[43..16]", "    gp = g_raw[35..16]"]},
    G.sat("dp_r", "dq_r", 28, 24),
    G.sat("dp_i", "dq_i", 28, 24),
    G.smul("n_rr", "dn_r", 18, "dn_r", 18),
    G.smul("n_ii", "dn_i", 18, "dn_i", 18),
    {["  wire :nz_c, 43", "  wire :d0_r, 24", "  wire :d0_i, 24", "  wire :g0, 20", "  wire :sum_r, 26", "  wire :sum_i, 26", "  wire :g_sum, 21"],
     [
       "    nz_c = #{G.sx("n_rr", 36, 43)} + #{G.sx("n_ii", 36, 43)}",
       "    d0_r = rd[67..44]",
       "    d0_i = rd[43..20]",
       "    g0 = rd[19..0]",
       # Two sat24 terms always fit 25 bits: the model's sat25 is a no-op here.
       "    sum_r = #{G.sx("dp_r", 24, 26)} + #{G.sx("d0_r", 24, 26)}",
       "    sum_i = #{G.sx("dp_i", 24, 26)} + #{G.sx("d0_i", 24, 26)}",
       "    g_sum = {zero1, gp} + {zero1, g0}"
     ]}
  ])

{dp_decls, dp_comb} = datapath

src = ~S'''
defmodule MimoHalow.Hw.Rx.MrcCombiner do
  @moduledoc """
  Two-chain MRC combiner: the receive block of the `:siso`, `:mrc_1x2` and
  `:eigen_1ss` modes (with a beamformed LTF the per-chain estimate is the
  effective channel `H v`). GENERATED by `scripts/gen_mrc_combiner.exs`;
  edit the generator, not this file.

  Bit-exact twin of `MimoHalow.Model.Fixed.Mrc`. Division-free, as the
  OcuSync equaliser it derives from: per data subcarrier it emits
  `D = sum_r sat24((sat25(Y_r >> scale) conj(Hn_r)) >> 16)` and
  `G = sum_r |Hn_r|^2 >> 16`; the point is `D / G`, its noise variance
  `sigma^2 / G`.

  Input (`Iface.Bins`): FFT bins in FFT output order, bin 0 first, each
  symbol as chain 0's 64 bins then chain 1's, tagged `in_tag = {flush,
  symbol}`; flush bins are dropped. Symbol 0 = LTF1, 1 = LTF2, 2.. = data.
  Bins arrive at least 4 cycles apart.

  * LTF1: L1 stored per `{chain, bin}`; `scale = max(0, bitlen(OR over both
    chains |L1r|, |L1i|) - 16)`, one shift for both chains.
  * LTF2: `Hn = sat18(((L1 + L2) s_k) >> scale)` stored per `{chain, bin}`;
    `noise = (sum over chains and used bins |sat18((L1 - L2) >> scale)|^2) >> 1`.
  * Data symbols, chain 0: `{D_0, G_0}` per used bin into `dbuf`. Chain 1:
    emits `{D_0 + D_1, G_0 + G_1}` for every used bin as it arrives (FFT
    order): data tones with `e_d` the data index, pilots with `e_pilot = 1`
    and `e_d` the pilot index; `e_last` on the last used bin in that order.

  Common-phase (pilot) tracking is not here: `MimoHalow.Hw.Rx.Cpe` follows
  the combiner and is shared by every MIMO mode. Products use the LtfSync
  unsigned-plus-sign-correction idiom.

  Contains written memories: verified under iverilog only.
  """

  use Hw.Component

  clock :clk, freq: 32.0

  input :enable, 1
  input :in_valid, 1
  input :in_i, 26
  input :in_q, 26
  input :in_bin, 6
  input :in_chain, 1
  input :in_tag, 12

  output :e_valid, 1
  output :e_i, 26
  output :e_q, 26
  output :e_g, 21
  output :e_d, 6
  output :e_j, 11
  output :e_stream, 1
  output :e_last, 1
  output :e_pilot, 1
  output :scale, 4
  output :noise, 42

  memory :l1mem, width: 52, depth: 128, sync_read: :clk
  memory :hmem, width: 36, depth: 128, sync_read: :clk
  memory :dbuf, width: 68, depth: 64, sync_read: :clk

  wire :zero1, 1
  wire :zero18, 18
  wire :zero25, 25
  wire :zero26, 26
  wire :zero28, 28
  wire :zero36, 36
  wire :zero43, 43

  # --- input register and per-bin ROM -------------------------------------------
  wire :i_v, 1, init: 0
  wire :i_r, 26, init: 0
  wire :i_q, 26, init: 0
  wire :i_bin, 6, init: 0
  wire :i_ch, 1, init: 0
  wire :i_sym, 11, init: 0
  wire :i_used, 1
  wire :i_sneg, 1
  wire :i_data, 1
  wire :i_pil, 1
  wire :i_dix, 6
  wire :i_dlast, 1
  wire :is0, 1
  wire :is1, 1
  wire :isd, 1
  wire :a7, 7

  # --- pipeline / state ---------------------------------------------------------
  wire :r_v, 1, init: 0
  wire :s_v, 1, init: 0
  wire :or_acc, 26, init: 0
  wire :sh, 4, init: 0
  wire :sh_c, 4
  wire :abs_r, 26
  wire :abs_i, 26
  wire :noise_acc, 43, init: 0
  wire :yn_r, 25, init: 0
  wire :yn_i, 25, init: 0
  wire :dn_r, 18, init: 0
  wire :dn_i, 18, init: 0
  wire :dr_raw, 44, init: 0
  wire :di_raw, 44, init: 0
  wire :g_raw, 37, init: 0
  wire :l1rd, 52
  wire :hrd, 36
  wire :rd, 68

  # --- output registers -----------------------------------------------------------
  wire :o_v, 1, init: 0
  wire :o_i, 26, init: 0
  wire :o_q, 26, init: 0
  wire :o_g, 21, init: 0
  wire :o_d, 6, init: 0
  wire :o_j, 11, init: 0
  wire :o_last, 1, init: 0
  wire :o_pil, 1, init: 0
@@DP_DECLS@@

  comb do
    zero1 = 0
    zero18 = 0
    zero25 = 0
    zero26 = 0
    zero28 = 0
    zero36 = 0
    zero43 = 0

    i_used = 0
    i_sneg = 0
    i_data = 0
    i_pil = 0
    i_dix = 0
    i_dlast = 0
    case i_bin do
@@ROM_ARMS@@
    end
    is0 = if i_sym == 0 do 1 else 0 end
    is1 = if i_sym == 1 do 1 else 0 end
    isd = if i_sym >= 2 do 1 else 0 end

    abs_r = if i_r[25..25] == 1 do zero26 - i_r else i_r end
    abs_i = if i_q[25..25] == 1 do zero26 - i_q else i_q end
    sh_c = @@PENC@@

    a7 = {i_ch, i_bin}
    l1rd = l1mem[a7]
    hrd = hmem[a7]
    rd = dbuf[i_bin]
@@DP_COMB@@

    e_valid = o_v
    e_i = o_i
    e_q = o_q
    e_g = o_g
    e_d = o_d
    e_j = o_j
    e_stream = 0
    e_last = o_last
    e_pilot = o_pil
    scale = sh
    noise = noise_acc[42..1]
  end

  # I: register one FFT bin (flush-symbol bins are dropped here).
  on :clk do
    i_v = 0
    if enable == 1 and in_valid == 1 and in_tag[11..11] == 0 do
      i_v = 1
      i_r = in_i
      i_q = in_q
      i_bin = in_bin
      i_ch = in_chain
      i_sym = in_tag[10..0]
    end
  end

  # c1..c3 per bin.
  on :clk do
    r_v = i_v
    s_v = r_v
    o_v = 0

    # c1: PPDU reset, LTF1 store and scale, Yn; the scale latches at LTF2's first bin.
    if i_v == 1 do
      yn_r = yn_r_c
      yn_i = yn_i_c
      if is0 == 1 and i_ch == 0 and i_bin == 0 do
        or_acc = 0
        noise_acc = 0
      end
      if is0 == 1 and i_used == 1 do
        l1mem[a7] = {i_r, i_q}
        or_acc = bor(or_acc, bor(abs_r, abs_i))
      end
      if is1 == 1 and i_ch == 0 and i_bin == 0 do
        sh = sh_c
      end
    end

    # c2: LTF2 -> Hn (stored), dn; data -> this chain's D, G products.
    if r_v == 1 do
      if is1 == 1 and i_used == 1 do
        hmem[a7] = {hn_r_c, hn_i_c}
        dn_r = dn_r_c
        dn_i = dn_i_c
      end
      if isd == 1 and i_data == 1 do
        dr_raw = dr_c
        di_raw = di_c
        g_raw = g_c
      end
    end

    # c3: noise; chain 0 stores D, G; chain 1 emits the sums.
    if s_v == 1 do
      if is1 == 1 and i_used == 1 do
        noise_acc = noise_acc + nz_c
      end
      if isd == 1 and i_data == 1 do
        if i_ch == 0 do
          dbuf[i_bin] = {dp_r, dp_i, gp}
        else
          o_v = 1
          o_i = sum_r
          o_q = sum_i
          o_g = g_sum
          o_d = i_dix
          o_j = i_sym - 2
          o_last = i_dlast
          o_pil = i_pil
        end
      end
    end
  end
end
'''

src =
  src
  |> String.replace("@@DP_DECLS@@", Enum.join(dp_decls, "\n"))
  |> String.replace("@@ROM_ARMS@@", Enum.join(rom_arms, "\n"))
  |> String.replace("@@PENC@@", penc)
  |> String.replace("@@DP_COMB@@", Enum.join(dp_comb, "\n"))

out = Path.expand("../lib/mimo_halow/hw/rx/mrc_combiner.ex", __DIR__)
File.mkdir_p!(Path.dirname(out))
File.write!(out, src)
IO.puts("wrote #{out} (#{src |> String.split("\n") |> length()} lines); last used bin in FFT order: #{last_used_bin}")
