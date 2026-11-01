defmodule MimoHalow.Model.Mimo.Trace do
  @moduledoc """
  Measured 2x2 channels from sounder captures (`cap_<tag>_<tx>.etf`), mapped
  onto the S1G 2 MHz data subcarriers: the sounder's 31.25 kHz tones are the
  S1G subcarrier spacing, so tone k is subcarrier k.
  """
  alias MimoHalow.Model.{Cx, Mat2, Sounder}
  alias MimoHalow.Model.Mimo.OfdmChannel

  @doc "Links of one capture file: `%{{tx_node, rx_node} => %{tone => H}}`."
  def load(file) do
    d = file |> File.read!() |> :erlang.binary_to_term()

    for {rx, {:ok, c}} <- d.caps, into: %{} do
      {{d.txb, rx}, c.u64 |> Sounder.decode_capture() |> Sounder.analyse() |> Sounder.mean_h()}
    end
  end

  @doc "All links of one round (`cap_<tag>_*.etf` in `dir`)."
  def load_round(dir, tag) do
    dir
    |> Path.join("cap_#{tag}_*.etf")
    |> Path.wildcard()
    |> Enum.map(&load/1)
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  @doc "H on the S1G data subcarriers, scaled to unit mean per-entry power."
  def subcarriers(hk) do
    hs = Enum.map(OfdmChannel.data_subcarriers(), &Map.fetch!(hk, &1))
    p = Enum.sum(Enum.map(hs, &Mat2.frob2/1)) / (4 * length(hs))
    k = 1 / :math.sqrt(p)
    Enum.map(hs, fn {{a, b}, {c, d}} -> {{Cx.scale(a, k), Cx.scale(b, k)}, {Cx.scale(c, k), Cx.scale(d, k)}} end)
  end

  @doc "Per-entry power (dB, relative to the mean) and median eigenvalue spread (dB)."
  def stats(hs) do
    pw = for rx <- 0..1, tx <- 0..1, do: Enum.sum(for h <- hs, do: Cx.abs2(Sounder.entry(h, rx, tx))) / length(hs)

    spread =
      hs
      |> Enum.map(fn h ->
        {_, {s1, s2}, _} = Mat2.svd(h)
        10 * :math.log10(s1 * s1 / max(s2 * s2, 1.0e-30))
      end)
      |> Enum.sort()
      |> Enum.at(div(length(hs), 2))

    %{power_db: Enum.map(pw, &Float.round(10 * :math.log10(&1), 1)), eig_spread_db: Float.round(spread, 1)}
  end

  @doc "Short board label from the node's address (.60 a, .62 b, .63 c)."
  def label(node) do
    case node |> Atom.to_string() |> String.split(".") |> List.last() do
      "60" -> "a"
      "62" -> "b"
      "63" -> "c"
      x -> x
    end
  end
end
