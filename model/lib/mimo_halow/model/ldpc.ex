defmodule MimoHalow.Model.Ldpc do
  @moduledoc """
  QC-LDPC, 802.11n family: n = 648, rate 1/2, Z = 27 (24 x 12 prototype).
  Notes/ocusync/02: one layered min-sum decoder for all rates; more
  prototypes (1296/1944, 2/3, 3/4, 5/6) drop in as tables.

  **Provenance.** The prototype below was transcribed from memory of the
  IEEE 802.11n (802.11-2012 Annex F / 802.11-2020 Table 19-*) n = 648,
  R = 1/2 matrix. 2026-10-24: identical, entry for entry (12 x 24, 88
  non-zero blocks), to simgunz/802.11n-ldpc `protoH/648_12` (sha1
  858e5c4479c87115432cd3ff6ba3b8fce9e69edb), an independent third-party
  table. Not yet compared against the standard text itself.

  Conventions. Entry `h` (or -1 for zero) of block (i, j) is the Z x Z
  identity cyclically shifted so that row r has its 1 in column
  (r + h) mod Z: `(P^h x)[r] = x[(r + h) mod Z]`. Blocks are Z-bit integers
  (bit r = codeword bit j*Z + r). LLRs are `log P(b=0) / P(b=1)`.

  Encoder: the 802.11n parity part is dual-diagonal. The first parity
  column has three entries (x, 0, x), so summing all block rows gives
  p_0 = sum(lambda_i); the staircase then yields p_1..p_(m-1).

  Decoder: layered normalized min-sum (alpha 0.75), block rows in order,
  early stop on a zero syndrome.
  """
  import Bitwise

  @proto_648_r12 """
   0 -1 -1 -1  0  0 -1 -1  0 -1 -1  0  1  0 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1
  22  0 -1 -1 17 -1  0  0 12 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1 -1 -1 -1
   6 -1  0 -1 10 -1 -1 -1 24 -1  0 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1 -1 -1
   2 -1 -1  0 20 -1 -1 -1 25  0 -1 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1 -1
  23 -1 -1 -1  3 -1 -1 -1  0 -1  9 11 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1
  24 -1 23  1 17 -1  3 -1 10 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1
  25 -1 -1 -1  8 -1 -1 -1  7 18 -1 -1  0 -1 -1 -1 -1 -1  0  0 -1 -1 -1 -1
  13 24 -1 -1  0 -1  8 -1  6 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1 -1 -1
   7 20 -1 16 22 10 -1 -1 23 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1 -1
  11 -1 -1 -1 19 -1 -1 -1 13 -1  3 17 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1
  25 -1  8 -1 23 18 -1 14  9 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0
   3 -1 -1 -1 16 -1 -1  2 25  5 -1 -1  1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0
  """

  @alpha 0.75

  @doc "Code parameters and the expanded H (cached)."
  def code(name \\ :n648_r12)

  def code(:n648_r12) do
    case :persistent_term.get({__MODULE__, :n648_r12}, nil) do
      nil ->
        c = build(@proto_648_r12, 27)
        :persistent_term.put({__MODULE__, :n648_r12}, c)
        c

      c ->
        c
    end
  end

  defp build(text, z) do
    base =
      text
      |> String.split("\n", trim: true)
      |> Enum.map(fn l -> l |> String.split() |> Enum.map(&String.to_integer/1) end)

    mb = length(base)
    nb = length(hd(base))
    true = Enum.all?(base, &(length(&1) == nb))
    kb = nb - mb

    # Rows of H as lists of column indices; columns as lists of row indices.
    rows =
      for brow <- base, r <- 0..(z - 1) do
        for {h, j} <- Enum.with_index(brow), h >= 0, do: j * z + rem(r + h, z)
      end

    %{
      z: z, mb: mb, nb: nb, kb: kb, n: nb * z, k: kb * z,
      base: base,
      rows: List.to_tuple(rows)
    }
  end

  defp rot(x, 0, _z), do: x
  defp rot(x, h, z), do: (x >>> h ||| x <<< (z - h)) &&& (1 <<< z) - 1

  defp to_blocks(bits, z) do
    bits |> Enum.chunk_every(z) |> Enum.map(fn bs -> bs |> Enum.with_index() |> Enum.reduce(0, fn {b, r}, a -> a ||| b <<< r end) end)
  end

  defp from_blocks(blocks, z), do: Enum.flat_map(blocks, fn x -> for r <- 0..(z - 1), do: x >>> r &&& 1 end)

  @doc "Encode `k` info bits (list of 0/1) to an `n`-bit systematic codeword."
  def encode(info, c \\ code()) do
    %{z: z, mb: mb, kb: kb, base: base} = c
    true = length(info) == c.k
    s = info |> to_blocks(z) |> List.to_tuple()

    lambda =
      Enum.map(base, fn brow ->
        brow |> Enum.take(kb) |> Enum.with_index() |> Enum.reduce(0, fn
          {-1, _}, acc -> acc
          {h, j}, acc -> bxor(acc, rot(elem(s, j), h, z))
        end)
      end)

    # First parity column: shifts per block row (-1 = absent).
    col_k = Enum.map(base, &Enum.at(&1, kb))
    present = Enum.reject(col_k, &(&1 < 0))

    unless length(present) == 3 and Enum.count(present, &(&1 == 0)) == 1 and
             length(Enum.uniq(present -- [0])) == 1,
           do: raise("prototype parity column is not (x, 0, x)")

    p0 = Enum.reduce(lambda, 0, &bxor/2)
    lam = List.to_tuple(lambda)
    ck = List.to_tuple(col_k)
    term = fn i -> if elem(ck, i) >= 0, do: rot(p0, elem(ck, i), z), else: 0 end

    # Row 0: lambda_0 + term_0 + p_1 = 0; row i: lambda_i + term_i + p_i + p_(i+1) = 0.
    p1 = bxor(elem(lam, 0), term.(0))

    {ps, _} =
      Enum.map_reduce(1..(mb - 2)//1, p1, fn i, pi ->
        nxt = elem(lam, i) |> bxor(term.(i)) |> bxor(pi)
        {nxt, nxt}
      end)

    info ++ from_blocks([p0, p1 | ps], z)
  end

  @doc "Number of unsatisfied parity checks of a hard codeword."
  def syndrome_weight(bits, c \\ code()) do
    t = List.to_tuple(bits)

    c.rows
    |> Tuple.to_list()
    |> Enum.count(fn cols -> Enum.reduce(cols, 0, fn col, a -> bxor(a, elem(t, col)) end) == 1 end)
  end

  @doc """
  Decode `n` LLRs (log P0/P1). Options `:max_iter` (20), `:alpha` (0.75).
  Returns `%{info: [bits], iters: n, ok: syndrome == 0}`.
  """
  def decode(llr, opts \\ [], c \\ code()) do
    max_iter = Keyword.get(opts, :max_iter, 20)
    alpha = Keyword.get(opts, :alpha, @alpha)
    true = length(llr) == c.n
    l = :array.from_list(Enum.map(llr, &(&1 * 1.0)))
    rows = c.rows
    nrows = tuple_size(rows)
    r0 = List.to_tuple(for i <- 0..(nrows - 1), do: List.to_tuple(List.duplicate(0.0, length(elem(rows, i)))))
    iterate(l, r0, rows, c, alpha, max_iter, 1)
  end

  defp iterate(l, r, rows, c, alpha, max_iter, it) do
    {l, r} =
      Enum.reduce(0..(tuple_size(rows) - 1), {l, r}, fn i, {l, r} ->
        cols = elem(rows, i)
        old = elem(r, i)

        t =
          cols
          |> Enum.with_index()
          |> Enum.map(fn {col, e} -> :array.get(col, l) - elem(old, e) end)

        {min1, min2, imin, sgn} =
          t
          |> Enum.with_index()
          |> Enum.reduce({1.0e30, 1.0e30, -1, 1}, fn {v, e}, {m1, m2, im, s} ->
            a = abs(v)
            s = if v < 0, do: -s, else: s

            cond do
              a < m1 -> {a, m1, e, s}
              a < m2 -> {m1, a, im, s}
              true -> {m1, m2, im, s}
            end
          end)

        new =
          t
          |> Enum.with_index()
          |> Enum.map(fn {v, e} ->
            mag = if e == imin, do: min2, else: min1
            sv = if v < 0, do: -sgn, else: sgn
            alpha * sv * mag
          end)

        l =
          Enum.zip([cols, t, new])
          |> Enum.reduce(l, fn {col, tv, nv}, acc -> :array.set(col, tv + nv, acc) end)

        {l, put_elem(r, i, List.to_tuple(new))}
      end)

    hard = for i <- 0..(c.n - 1), do: if(:array.get(i, l) < 0, do: 1, else: 0)
    ok = syndrome_weight(hard, c) == 0

    if ok or it >= max_iter do
      %{info: Enum.take(hard, c.k), iters: it, ok: ok}
    else
      iterate(l, r, rows, c, alpha, max_iter, it + 1)
    end
  end
end
