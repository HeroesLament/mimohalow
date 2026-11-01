defmodule MimoHalow.Model.Fixed.DataDec do
  @moduledoc """
  Bit-exact model of the S1G DATA back end (`MimoHalow.Hw.Rx.DataDec`): the
  `Cpe` output of the DATA symbols to PSDU bytes. 2 MHz, 1 SS, BCC.

  1. **Demap**, per tone `{D', G}` (`D'` = Cpe output, gain K/2 G x on the
     unit-power point x), per axis with m bits, Gray PAM, log P0/P1
     (positive = 0): `L0 = -v`, `L1 = |v| - T1`, `Lk = |L(k-1)| - Tk`,
     `Tk = (G ck) >> 16`, `ck = round(65536 (K/2) kmod 2^(m-k))`. I bits
     then Q bits (BPSK: one bit on I).
  2. **Soft**: `s = clamp(-L >> q, -31, 31)` (positive = coded 1), `q =
     max(0, bitlen(sum G >> 6) - 4 - smod)`, sum over the 52 tones of the
     first SIG symbol, `smod` = 0 / 0 / 2 / 3 / 4 for BPSK .. 256-QAM.
  3. **Deinterleave** per symbol (`S1g.Coding.deinterleave/3`) and
     **depuncture** (erasure 0), one pair per information bit.
  4. **Viterbi**, K = 7, 133 / 171, 64 states, metric +s for a coded 1 and
     -s for a 0, maximised; state 0 starts at 0, the others at -16384; each
     state takes its even predecessor unless the odd one is strictly
     greater. Block traceback: after every B = 64 steps past the first D +
     B (D = 96), trace back from state 0 at the newest step over D + B steps
     and release the oldest B bits; at the end, trace back from state 0
     (terminated) over everything not yet released.
  5. **Descramble**: the first 7 decoded bits are the scrambler's output,
     which is what shifted into it: register x1 = the 7th bit .. x7 = the
     1st; descramble from bit 7 on. PSDU = bits 8.. (LSB
     first per byte), LENGTH bytes, or `(nsym Ndbps - 14) div 8` when
     aggregated.
  """
  import Bitwise
  alias MimoHalow.Model.{Qam, Scrambler}
  alias MimoHalow.Model.S1g.{Coding, Params}

  @k Enum.reduce(0..15, 1.0, fn i, acc -> acc * :math.sqrt(1 + :math.pow(2, -2 * i)) end)
  @b 64
  @d 96

  def depth, do: {@b, @d}

  @doc "Thresholds `[T1 .. T(m-1)]` constants c_k for `mod`."
  def consts(mod) do
    m = max(div(Qam.nbpsc(mod), 2), 1)
    km = Qam.k_mod(mod)
    for k <- 1..(m - 1)//1, do: round(65536 * (@k / 2) * km * :math.pow(2, m - k))
  end

  def smod(:bpsk), do: 0
  def smod(:qpsk), do: 0
  def smod(:qam16), do: 2
  def smod(:qam64), do: 3
  def smod(:qam256), do: 4

  @doc "Per-axis LLRs of value v with gain g."
  def axis(v, g, cs) do
    {ls, _} =
      Enum.reduce(cs, {[-v], -v}, fn c, {acc, prev} ->
        t = g * c >>> 16
        l = if length(acc) == 1, do: abs(v) - t, else: abs(prev) - t
        {acc ++ [l], l}
      end)

    ls
  end

  @doc "LLRs of one tone (I bits then Q bits)."
  def tone({xo, yo, g}, mod) do
    cs = consts(mod)
    if mod == :bpsk, do: [-xo], else: axis(xo, g, cs) ++ axis(yo, g, cs)
  end

  def scale(sig0_gs, mod) do
    s = Enum.sum(sig0_gs) >>> 6
    max(0, bitlen(s) - 4 - smod(mod))
  end

  def soft(l, q), do: (-l >>> q) |> max(-31) |> min(31)

  @doc """
  Stage 1-3: the soft pairs the Viterbi consumes, one `{sa, sb}` per
  information bit (erasure 0). `sig0_gs`: the 52 G of SIG symbol 0; `syms`:
  DATA symbols, each `[{xo, yo, g}]` in data-index order.
  """
  def pairs(sig0_gs, syms, mcs) do
    {:ok, r} = Params.rate(2, mcs)
    q = scale(sig0_gs, r.mod)
    geo = Params.interleaver(2, r.nbpsc)

    softs =
      Enum.flat_map(syms, fn tones ->
        tones |> Enum.flat_map(&tone(&1, r.mod)) |> Enum.map(&soft(&1, q)) |> Coding.deinterleave(geo, r.nbpsc)
      end)

    softs
    |> Coding.depuncture(r.rate, length(syms) * r.ndbps)
    |> Enum.map(fn x -> if is_float(x), do: round(x), else: x end)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [a, b] -> {a, b} end)
  end

  @doc "Stage 5: descrambled bits -> PSDU bytes."
  def psdu(bits, nsym, ndbps, len_bytes, aggr?) do
    len = if aggr?, do: div(nsym * ndbps - 14, 8), else: len_bytes
    bits |> Enum.drop(8) |> Enum.take(8 * len) |> Coding.bits_to_bytes()
  end

  @doc "Decode end to end. Returns `%{pairs:, raw:, bits:, psdu:, q:}`."
  def decode(sig0_gs, syms, mcs, len_bytes, aggr?) do
    {:ok, r} = Params.rate(2, mcs)
    ps = pairs(sig0_gs, syms, mcs)
    raw = viterbi(Enum.flat_map(ps, fn {a, b} -> [a, b] end))
    bits = descramble(raw)
    %{pairs: ps, raw: raw, bits: bits, psdu: psdu(bits, length(syms), r.ndbps, len_bytes, aggr?), q: scale(sig0_gs, r.mod)}
  end

  # --- Viterbi ------------------------------------------------------------------------

  # Next state s2 = (u << 5) | (s >> 1) for input u; predecessors (s2 << 1 & 63) | b.
  # Register for the outputs: (u << 6) | s.
  @outs List.to_tuple(
          for s2 <- 0..63 do
            u = s2 >>> 5

            for b <- 0..1 do
              s = (s2 <<< 1 &&& 63) ||| b
              w = u <<< 6 ||| s
              {s, rem(Enum.sum(Integer.digits(w &&& 0b1011011, 2)), 2), rem(Enum.sum(Integer.digits(w &&& 0b1111001, 2)), 2)}
            end
          end
        )

  def viterbi(softs) do
    pairs = softs |> Enum.chunk_every(2) |> Enum.map(fn [a, b] -> {a, b} end)
    n = length(pairs)
    pm0 = for(s <- 0..63, do: if(s == 0, do: 0, else: -16384)) |> List.to_tuple()

    {_, decs} =
      Enum.reduce(pairs, {pm0, []}, fn {sa, sb}, {pm, ds} ->
        {npm, d} =
          for s2 <- 0..63, reduce: {[], []} do
            {ms, dd} ->
              [{s0, a0, b0}, {s1, a1, b1}] = elem(@outs, s2)
              m0 = elem(pm, s0) + bm(a0, b0, sa, sb)
              m1 = elem(pm, s1) + bm(a1, b1, sa, sb)
              if m1 > m0, do: {[m1 | ms], [1 | dd]}, else: {[m0 | ms], [0 | dd]}
          end

        {npm |> Enum.reverse() |> List.to_tuple(), [d |> Enum.reverse() |> List.to_tuple() | ds]}
      end)

    decs = decs |> Enum.reverse() |> List.to_tuple()
    blocks(decs, n)
  end

  defp bm(a, b, sa, sb), do: if(a == 1, do: sa, else: -sa) + if(b == 1, do: sb, else: -sb)

  # Released bits in order: windows ending at t = D + B - 1 + k B, then the tail.
  defp blocks(decs, n) do
    ends = Stream.iterate(@d + @b - 1, &(&1 + @b)) |> Enum.take_while(&(&1 < n - 1))

    {out, released} =
      Enum.reduce(ends, {[], 0}, fn t, {acc, rel} ->
        bits = trace(decs, t, t - (@d + @b) + 1)
        {acc ++ Enum.take(bits, @b), rel + @b}
      end)

    out ++ trace(decs, n - 1, released)
  end

  # Trace back from state 0 at step t_hi down to t_lo; bits for steps t_lo..t_hi.
  defp trace(decs, t_hi, t_lo) do
    {bits, _} =
      Enum.reduce(t_hi..t_lo//-1, {[], 0}, fn t, {acc, s2} ->
        b = elem(elem(decs, t), s2)
        {[s2 >>> 5 | acc], (s2 <<< 1 &&& 63) ||| b}
      end)

    bits
  end

  # --- descrambler ------------------------------------------------------------------

  def descramble(raw) do
    {first, rest} = Enum.split(raw, 7)
    # register cell x_k (bit k-1) = first[7 - k]
    st = first |> Enum.with_index() |> Enum.reduce(0, fn {b, i}, a -> a ||| b <<< (6 - i) end)
    List.duplicate(0, 7) ++ Scrambler.scramble(rest, st)
  end

  defp bitlen(0), do: 0
  defp bitlen(m), do: length(Integer.digits(m, 2))
end
