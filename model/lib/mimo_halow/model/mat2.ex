defmodule MimoHalow.Model.Mat2 do
  @moduledoc """
  2x2 complex matrices as row tuples `{{a, b}, {c, d}}`, 2-vectors as `{x, y}`.
  """
  alias MimoHalow.Model.Cx

  @eps 1.0e-12

  def identity, do: {{Cx.new(1.0), Cx.zero()}, {Cx.zero(), Cx.new(1.0)}}

  def from_cols({a, c}, {b, d}), do: {{a, b}, {c, d}}
  def col({{a, _}, {c, _}}, 0), do: {a, c}
  def col({{_, b}, {_, d}}, 1), do: {b, d}

  def mul({{a, b}, {c, d}}, {{e, f}, {g, h}}) do
    {{dot2(a, e, b, g), dot2(a, f, b, h)}, {dot2(c, e, d, g), dot2(c, f, d, h)}}
  end

  def mulv({{a, b}, {c, d}}, {x, y}), do: {dot2(a, x, b, y), dot2(c, x, d, y)}

  def herm({{a, b}, {c, d}}), do: {{Cx.conj(a), Cx.conj(c)}, {Cx.conj(b), Cx.conj(d)}}

  def add_diag({{a, b}, {c, d}}, k), do: {{Cx.add(a, Cx.new(k)), b}, {c, Cx.add(d, Cx.new(k))}}

  def det({{a, b}, {c, d}}), do: Cx.sub(Cx.mul(a, d), Cx.mul(b, c))

  def inv({{a, b}, {c, d}} = m) do
    dt = det(m)
    s = &Cx.div(&1, dt)
    {{s.(d), s.(Cx.neg(b))}, {s.(Cx.neg(c)), s.(a)}}
  end

  def frob2({{a, b}, {c, d}}), do: Cx.abs2(a) + Cx.abs2(b) + Cx.abs2(c) + Cx.abs2(d)

  def vnorm2({x, y}), do: Cx.abs2(x) + Cx.abs2(y)
  def vscale({x, y}, k), do: {Cx.scale(x, k), Cx.scale(y, k)}
  def vadd({a, b}, {c, d}), do: {Cx.add(a, c), Cx.add(b, d)}
  def vsub({a, b}, {c, d}), do: {Cx.sub(a, c), Cx.sub(b, d)}
  def vdot({a, b}, {c, d}), do: Cx.add(Cx.mul(Cx.conj(a), c), Cx.mul(Cx.conj(b), d))

  @doc """
  Singular value decomposition `h = u * diag(s1, s2) * v^H`, s1 >= s2 >= 0,
  from the closed-form eigendecomposition of the Hermitian `h^H h`.
  Returns `{u, {s1, s2}, v}`.
  """
  def svd(h) do
    {{p, q}, {_, r}} = mul(herm(h), h)
    {p, _} = p
    {r, _} = r
    half = (p - r) / 2
    root = :math.sqrt(half * half + Cx.abs2(q))
    l1 = (p + r) / 2 + root
    l2 = max((p + r) / 2 - root, 0.0)

    v1 =
      cond do
        Cx.abs2(q) > @eps -> normalize({q, Cx.new(l1 - p)})
        p >= r -> {Cx.new(1.0), Cx.zero()}
        true -> {Cx.zero(), Cx.new(1.0)}
      end

    v2 = orth(v1)
    s1 = :math.sqrt(l1)
    s2 = :math.sqrt(l2)
    u1 = if s1 > @eps, do: vscale(mulv(h, v1), 1.0 / s1), else: {Cx.new(1.0), Cx.zero()}
    u2 = if s2 > @eps, do: vscale(mulv(h, v2), 1.0 / s2), else: orth(u1)
    {from_cols(u1, u2), {s1, s2}, from_cols(v1, v2)}
  end

  defp orth({x, y}), do: {Cx.neg(Cx.conj(y)), Cx.conj(x)}
  defp normalize(v), do: vscale(v, 1.0 / :math.sqrt(vnorm2(v)))
  defp dot2(a, x, b, y), do: Cx.add(Cx.mul(a, x), Cx.mul(b, y))
end
