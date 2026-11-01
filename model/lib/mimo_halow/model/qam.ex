defmodule MimoHalow.Model.Qam do
  @moduledoc """
  802.11 constellation mapping: per-axis binary-reflected Gray PAM, the first
  half of each bit group on I and the second half on Q, unit average energy.
  """
  import Bitwise
  alias MimoHalow.Model.Cx

  @type mod :: :bpsk | :qpsk | :qam16 | :qam64 | :qam256

  def nbpsc(:bpsk), do: 1
  def nbpsc(:qpsk), do: 2
  def nbpsc(:qam16), do: 4
  def nbpsc(:qam64), do: 6
  def nbpsc(:qam256), do: 8

  def k_mod(:bpsk), do: 1.0
  def k_mod(:qpsk), do: 1 / :math.sqrt(2)
  def k_mod(:qam16), do: 1 / :math.sqrt(10)
  def k_mod(:qam64), do: 1 / :math.sqrt(42)
  def k_mod(:qam256), do: 1 / :math.sqrt(170)

  def mods, do: [:bpsk, :qpsk, :qam16, :qam64, :qam256]

  def map(bits, mod), do: bits |> Enum.chunk_every(nbpsc(mod)) |> Enum.map(&point(&1, mod))

  def point([b], :bpsk), do: Cx.new(level([b]))

  def point(bits, mod) do
    {i, q} = Enum.split(bits, div(nbpsc(mod), 2))
    Cx.new(level(i), level(q)) |> Cx.scale(k_mod(mod))
  end

  @doc "All `{bits, point}` pairs of `mod`."
  def constellation(mod) do
    n = nbpsc(mod)
    for v <- 0..((1 <<< n) - 1), b = bits_of(v, n), do: {b, point(b, mod)}
  end

  @doc "Bits of the constellation point nearest `x`."
  def slice(x, mod) do
    mod |> constellation() |> Enum.min_by(fn {_, p} -> Cx.abs2(Cx.sub(x, p)) end) |> elem(0)
  end

  def bits_of(v, n), do: for(k <- (n - 1)..0//-1, do: v >>> k &&& 1)

  defp level(bits) do
    n = length(bits)
    i = bits |> Integer.undigits(2) |> gray_to_bin()
    2.0 * i - ((1 <<< n) - 1)
  end

  defp gray_to_bin(g), do: gray_to_bin(g, g >>> 1)
  defp gray_to_bin(b, 0), do: b
  defp gray_to_bin(b, s), do: gray_to_bin(bxor(b, s), s >>> 1)
end
