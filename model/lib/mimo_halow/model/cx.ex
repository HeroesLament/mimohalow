defmodule MimoHalow.Model.Cx do
  @moduledoc "Complex numbers as `{re, im}` float tuples."

  @type t :: {float(), float()}

  def new(re, im \\ 0.0), do: {re * 1.0, im * 1.0}
  def zero, do: {0.0, 0.0}
  def add({a, b}, {c, d}), do: {a + c, b + d}
  def sub({a, b}, {c, d}), do: {a - c, b - d}
  def mul({a, b}, {c, d}), do: {a * c - b * d, a * d + b * c}
  def conj({a, b}), do: {a, -b}
  def neg({a, b}), do: {-a, -b}
  def scale({a, b}, k), do: {a * k, b * k}
  def abs2({a, b}), do: a * a + b * b
  def div(x, y), do: scale(mul(x, conj(y)), 1.0 / abs2(y))
  def expj(theta), do: {:math.cos(theta), :math.sin(theta)}
  def sum(xs), do: Enum.reduce(xs, zero(), &add/2)
end
