defmodule MimoHalow.Model.S1g.Coding do
  @moduledoc """
  S1G bit-level pieces: BCC puncturing, the 3-stage BCC interleaver
  (11ac form), MCS10 / 1 MHz SIG repetition, pilot polarity, CRC-4 (SIG)
  and CRC-32 (FCS). Bits are lists of 0/1; LLRs are log P(0)/P(1).
  """
  import Bitwise
  alias MimoHalow.Model.S1g.Params

  # --- puncturing -----------------------------------------------------------------

  @doc "Keep-pattern over rate-1/2 output pairs (A0 B0 A1 B1 ...)."
  def keep({1, 2}), do: [1, 1]
  def keep({2, 3}), do: [1, 1, 1, 0]
  def keep({3, 4}), do: [1, 1, 1, 0, 0, 1]
  def keep({5, 6}), do: [1, 1, 1, 0, 0, 1, 1, 0, 0, 1]

  def puncture(coded, rate) do
    pat = keep(rate)
    coded |> Enum.zip(Stream.cycle(pat)) |> Enum.flat_map(fn {b, 1} -> [b]; {_, 0} -> [] end)
  end

  @doc "Re-insert erasures (LLR 0.0) for `n_pairs` rate-1/2 output pairs."
  def depuncture(llrs, rate, n_pairs) do
    pat = keep(rate)

    {out, _} =
      Stream.cycle(pat)
      |> Enum.take(2 * n_pairs)
      |> Enum.map_reduce(llrs, fn
        1, [l | rest] -> {l, rest}
        1, [] -> {0.0, []}
        0, rest -> {0.0, rest}
      end)

    out
  end

  # --- interleaver ----------------------------------------------------------------

  @doc "Output position of input bit k (one spatial stream, iss = 1)."
  def perm(%{ncol: ncol, nrow: nrow}, nbpsc, ncbps, iss \\ 1, nrot \\ 0) do
    s = max(div(nbpsc, 2), 1)
    r = rem(2 * (iss - 1), 3) + 3 * div(iss - 1, 3)

    for k <- 0..(ncbps - 1) do
      i = nrow * rem(k, ncol) + div(k, ncol)
      j = s * div(i, s) + rem(i + ncbps - div(ncol * i, ncbps), s)
      Integer.mod(j - r * nrot * nbpsc, ncbps)
    end
  end

  def interleave(bits, geo, nbpsc) do
    n = length(bits)
    p = perm(geo, nbpsc, n)
    Enum.zip(p, bits) |> Enum.sort() |> Enum.map(&elem(&1, 1))
  end

  def deinterleave(vals, geo, nbpsc) do
    t = List.to_tuple(vals)
    geo |> perm(nbpsc, length(vals)) |> Enum.map(&elem(t, &1))
  end

  # --- repetition (1 MHz SIG, MCS10) ---------------------------------------------------

  def rep2(bits12), do: bits12 ++ Enum.zip_with(bits12, Params.s_rep(), &bxor/2)

  @doc "Combine the two copies' LLRs (the second is sign-flipped where s = 1)."
  def unrep2(llrs24) do
    {a, b} = Enum.split(llrs24, 12)
    Enum.zip_with([a, b, Params.s_rep()], fn [x, y, s] -> x + if(s == 1, do: -y, else: y) end)
  end

  # --- pilot polarity -----------------------------------------------------------------

  @polarity (
              {bits, _} =
                Enum.map_reduce(1..127, 0x7F, fn _, st ->
                  fb = bxor(st >>> 6 &&& 1, st >>> 3 &&& 1)
                  {fb, (st <<< 1 ||| fb) &&& 0x7F}
                end)

              bits |> Enum.map(&(1 - 2 * &1)) |> List.to_tuple()
            )

  def polarity(n), do: elem(@polarity, rem(n, 127))

  @doc "Pilot values of symbol `m` (rotation index), polarity index `n`."
  def pilot_values(bw, m, n, rotate? \\ true) do
    pat = Params.pilot_pattern(bw)
    np = length(pat)
    pat = if rotate?, do: Enum.map(0..(np - 1), &Enum.at(pat, rem(&1 + m, np))), else: pat
    Enum.zip(Params.pilots(bw), Enum.map(pat, &(&1 * polarity(n)))) |> Map.new()
  end

  # --- CRCs ----------------------------------------------------------------------------

  @doc "SIG CRC-4, x^4 + x + 1, init 1111, ones' complement out (4 bits, c3 first)."
  def crc4(bits) do
    reg =
      Enum.reduce(bits, [1, 1, 1, 1], fn x, [r0, r1, r2, r3] ->
        t = bxor(x, r0)
        [r1, r2, bxor(r3, t), t]
      end)

    Enum.map(reg, &(1 - &1))
  end

  @doc "FCS: CRC-32 over bits (LSB-first bytes), transmitted complemented."
  def fcs(bits) do
    crc =
      bits
      |> Enum.chunk_every(8)
      |> Enum.reduce(0xFFFFFFFF, fn byte, c ->
        b = byte |> Enum.with_index() |> Enum.reduce(0, fn {v, i}, a -> a ||| v <<< i end)
        Enum.reduce(0..7, bxor(c, b), fn _, c -> if (c &&& 1) == 1, do: bxor(c >>> 1, 0xEDB88320), else: c >>> 1 end)
      end)

    crc = bxor(crc, 0xFFFFFFFF)
    for i <- 0..31, do: crc >>> i &&& 1
  end

  @doc "LSB-first bit list of `v`, `n` bits."
  def bits(v, n), do: for(i <- 0..(n - 1), do: v >>> i &&& 1)
  def value(bits), do: bits |> Enum.with_index() |> Enum.reduce(0, fn {b, i}, a -> a ||| b <<< i end)

  def bytes_to_bits(bin), do: for(<<b <- bin>>, i <- 0..7, do: b >>> i &&& 1)
  def bits_to_bytes(bits), do: bits |> Enum.chunk_every(8) |> Enum.map(&value/1) |> :binary.list_to_bin()
end
