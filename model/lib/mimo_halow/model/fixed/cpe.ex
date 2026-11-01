defmodule MimoHalow.Model.Fixed.Cpe do
  @moduledoc """
  Bit-exact model of the common-phase (pilot) stage, `MimoHalow.Hw.Rx.Cpe`.
  It follows the MRC combiner (or any detector emitting per-tone `{D, G}`
  with pilots flagged) and is shared by every MIMO mode.

  Per OFDM symbol `j` (0 = first symbol after LTF1):

  * `C = sum over pilots i of v_i(j) D_i`, with `v_i(j) = +-1` the S1G
    pilot value (`S1g.Coding.pilot_values/4`: fixed pattern in the 2 MHz
    SIG, rotating in data and in the whole 1 MHz PPDU, times polarity p_j).
  * `theta = atan2(C)` in 16-bit turns: normalise to 20 significant bits,
    fold a half turn when x < 0, 16 vectoring CORDIC steps (OcuSync's
    `EqFixed`).
  * Each data tone, in data-index order: `D' = rot(sat25(D), -theta)` by the
    table rotator (`Hw.RotTab` spec, gain K = 1.6468), G unchanged. The
    point is `D' / (K G)`.
  """
  import Bitwise
  alias MimoHalow.Model.S1g.{Coding, Params}

  @atan for i <- 0..15, do: round(:math.atan(:math.pow(2, -i)) / (2 * :math.pi()) * 65536)
  @k Enum.reduce(0..15, 1.0, fn i, acc -> acc * :math.sqrt(1 + :math.pow(2, -2 * i)) end)
  @table for(i <- 0..1023, do: round(@k * 65536 * :math.cos(2 * :math.pi() * i / 4096))) |> List.to_tuple()

  def gain, do: @k

  @doc "Pilot sign (true = -1) of pilot index `i` in symbol `j`."
  def pilot_neg?(bw, i, j) do
    k = Enum.at(Params.pilots(bw), i)
    m = if bw == 2, do: j - 2, else: j
    v = if bw == 2 and j < 2, do: Coding.pilot_values(2, 0, j, false), else: Coding.pilot_values(bw, m, j)
    v[k] < 0
  end

  @doc """
  One symbol. `tones`: `[{pilot? (0/1), d, dr, di, g}]` (any order).
  Returns `{theta, [{d, xo, yo, g}]}` with data tones in d order.
  """
  def symbol(bw, j, tones) do
    {cr, ci} =
      tones
      |> Enum.filter(&(elem(&1, 0) == 1))
      |> Enum.reduce({0, 0}, fn {1, i, dr, di, _g}, {ar, ai} ->
        if pilot_neg?(bw, i, j), do: {ar - dr, ai - di}, else: {ar + dr, ai + di}
      end)

    theta = atan2(ci, cr)
    nega = wrap(-theta, 16)

    out =
      tones
      |> Enum.filter(&(elem(&1, 0) == 0))
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(fn {0, d, dr, di, g} ->
        {xo, yo} = rotate(sat(dr, 25), sat(di, 25), nega)
        {d, xo, yo, g}
      end)

    {theta, out}
  end

  # sat to w bits, symmetric (keeps |x| < 2^(w-1) for the rotator's quadrant swap).
  defp sat(v, w), do: v |> max(-(1 <<< (w - 1)) + 1) |> min((1 <<< (w - 1)) - 1)

  def atan2(y, x) do
    {x, y} = normalize(x, y)
    {x, y, z} = if x < 0, do: {-x, -y, 32768}, else: {x, y, 0}

    {_, _, z} =
      @atan
      |> Enum.with_index()
      |> Enum.reduce({x, y, z}, fn {a, i}, {x, y, z} ->
        if y >= 0, do: {x + (y >>> i), y - (x >>> i), z + a}, else: {x - (y >>> i), y + (x >>> i), z - a}
      end)

    wrap(z, 16)
  end

  defp normalize(x, y) do
    m = abs(x) ||| abs(y)

    cond do
      m >= 1 <<< 20 -> normalize(x >>> 1, y >>> 1)
      m != 0 and m < 1 <<< 19 -> normalize(x <<< 1, y <<< 1)
      true -> {x, y}
    end
  end

  @doc "`Hw.RotTab` spec: (x, y) rotated by `a` (16-bit turns), gain K."
  def rotate(x, y, a) do
    p = (a + 8) >>> 4 &&& 4095
    q = p >>> 10
    r = p &&& 1023

    {x1, y1} =
      case q do
        0 -> {x, y}
        1 -> {-y, x}
        2 -> {-x, -y}
        3 -> {y, -x}
      end

    c = elem(@table, r)
    s = if r == 0, do: 0, else: elem(@table, 1024 - r)
    {(x1 * c - y1 * s + 32768) >>> 16, (x1 * s + y1 * c + 32768) >>> 16}
  end

  def wrap(v, bits) do
    m = v &&& (1 <<< bits) - 1
    if m >= 1 <<< (bits - 1), do: m - (1 <<< bits), else: m
  end
end
