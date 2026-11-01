defmodule MimoHalow.Model.Fixed.Decim4 do
  @moduledoc """
  Bit-exact model of `MimoHalow.Hw.Rx.Decim4`: 8 MS/s -> 2 MS/s per
  stream (I, Q of both chains), two Kaiser half-band stages.

  * HB1, 8 -> 4 MS/s: 15 taps, beta 6, Q15. On every odd input index n:
    `y1 = sat13((sum_k h1[k] x[n - k] + 2^14) >> 15)`.
  * HB2, 4 -> 2 MS/s: 59 taps, beta 5.5, Q17. On every odd y1 index m:
    `y2 = sat12((sum_k h2[k] y1[m - k] + 2^16) >> 17)`.
  * Half-band: odd offsets from the centre are 0 and the centre is exactly
    0.5, so HB1 has 4 coefficient pairs + centre and HB2 15 + centre.

  Cascade: passband droop 0.01 dB to 0.875 MHz, worst alias rejection
  -52.7 dB from 1.125 MHz (HB1 alone -62.9 dB on its 3.125 - 4 MHz band).

  The S1G 2 MHz signal occupies +-0.875 MHz; HB2's alias edge is 1.125 MHz
  (where the adjacent 2 MHz channel starts).
  """
  import Bitwise

  @doc "Half-band taps: n taps (odd), Kaiser beta, quantised to `q` bits (centre 2^(q-1))."
  def halfband(n, beta, q) do
    c = div(n - 1, 2)

    for k <- 0..(n - 1) do
      m = k - c

      cond do
        m == 0 -> 1 <<< (q - 1)
        rem(m, 2) == 0 -> 0
        true ->
          s = :math.sin(:math.pi() * m / 2) / (:math.pi() * m)
          w = i0(beta * :math.sqrt(1 - :math.pow(m / c, 2))) / i0(beta)
          round(s * w * (1 <<< q))
      end
    end
  end

  def h1, do: halfband(15, 6.0, 15)
  def h2, do: halfband(59, 5.5, 17)

  defp i0(x) do
    Enum.reduce_while(1..60, {1.0, 1.0}, fn k, {sum, term} ->
      t = term * :math.pow(x / 2 / k, 2)
      if t < 1.0e-12 * sum, do: {:halt, {sum + t, t}}, else: {:cont, {sum + t, t}}
    end)
    |> elem(0)
  end

  defp sat(v, w), do: v |> max(-(1 <<< (w - 1))) |> min((1 <<< (w - 1)) - 1)

  @doc "One integer stream at 8 MS/s -> 2 MS/s."
  def run(xs) do
    y1 = fir_decim(xs, h1(), 15, 13)
    fir_decim(y1, h2(), 17, 12)
  end

  # Output at odd input indices n: sum h[k] x[n - k], zero history.
  defp fir_decim(xs, h, q, w) do
    t = List.to_tuple(xs)

    for i <- 1..(tuple_size(t) - 1)//2 do
      acc =
        h
        |> Enum.with_index()
        |> Enum.reduce(0, fn {c, k}, a -> if i - k >= 0 and c != 0, do: a + c * elem(t, i - k), else: a end)

      sat((acc + (1 <<< (q - 1))) >>> q, w)
    end
  end

  @doc "Complex helper: [{i, q}] -> [{i, q}]."
  def run_cx(xs) do
    Enum.zip(run(Enum.map(xs, &elem(&1, 0))), run(Enum.map(xs, &elem(&1, 1))))
  end

  @doc "Float magnitude response of the cascade at f (Hz) for 8 MS/s input."
  def response(f) do
    w1 = 2 * :math.pi() * f / 8.0e6
    w2 = 2 * :math.pi() * f / 4.0e6
    mag = fn h, q, w ->
      {re, im} = h |> Enum.with_index() |> Enum.reduce({0.0, 0.0}, fn {c, k}, {a, b} -> {a + c * :math.cos(w * k), b - c * :math.sin(w * k)} end)
      :math.sqrt(re * re + im * im) / (1 <<< q)
    end

    mag.(h1(), 15, w1) * mag.(h2(), 17, w2)
  end
end
