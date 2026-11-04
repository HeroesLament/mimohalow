defmodule MimoHalow.Model.S1g.Air do
  @moduledoc """
  S1G 2 MHz PPDUs on the air from the LibreSDR board top's TX DMA ring.

  The ring (`Nervezynq.TxLoop.dma_load/1`) is 131,072 frames played cyclically
  at 8 MS/s, one little-endian u64 per frame: I1 [11:0], Q1 [23:12], I2
  [35:24], Q2 [47:36], 12-bit two's complement. `Ppdu.tx/2` builds base-rate
  (2 MS/s) samples; `interp4/1` brings them to 8 MS/s through the receive
  path's own half-bands (`Fixed.Decim4.h2/0` at 2 -> 4 MS/s, `h1/0` at
  4 -> 8 MS/s), each zero-stuffed and filtered with a gain of 2.

  A PSDU on the air carries an 802.11 FCS (`with_fcs/1`): the fabric PHY
  checks only the SIG CRC-4, so payload integrity is checked on the host
  (`Ppdu.fcs_ok?/1`).
  """
  import Bitwise

  alias MimoHalow.Model.Cx
  alias MimoHalow.Model.Fixed.Decim4
  alias MimoHalow.Model.S1g.{Coding, Ppdu}

  @ring_frames 131_072
  # RMS of the PPDU body in 12-bit units: -14 dBFS, ~11 dB of headroom for
  # the OFDM peaks before the 2047 clip.
  @rms 410.0

  @type cx :: {float(), float()}

  def ring_frames, do: @ring_frames

  @doc "`payload` with its 802.11 FCS (CRC-32, transmitted bit order) appended."
  @spec with_fcs(binary()) :: binary()
  def with_fcs(payload) when is_binary(payload) do
    fcs = payload |> Coding.bytes_to_bits() |> Coding.fcs() |> Coding.bits_to_bytes()
    payload <> fcs
  end

  @doc "2 MS/s -> 8 MS/s. Output length 4 * length(xs) + the filter tails."
  @spec interp4([cx()]) :: [cx()]
  def interp4(xs) do
    xs |> up2(Decim4.h2(), 17) |> up2(Decim4.h1(), 15)
  end

  # Zero-stuff by 2, then filter with the half-band at a gain of 2: the even
  # taps are zero but the centre, so the centre passes x through and the odd
  # taps fill the stuffed slots.
  defp up2(xs, h, q) do
    taps =
      h
      |> Enum.with_index()
      |> Enum.reject(fn {c, _} -> c == 0 end)
      |> Enum.map(fn {c, k} -> {2.0 * c / (1 <<< q), k} end)

    s = xs |> Enum.flat_map(&[&1, Cx.zero()]) |> List.to_tuple()
    n = tuple_size(s)
    last = n + length(h) - 2

    for i <- 0..last do
      Enum.reduce(taps, Cx.zero(), fn {c, k}, acc ->
        j = i - k
        if j >= 0 and j < n, do: Cx.add(acc, Cx.scale(elem(s, j), c)), else: acc
      end)
    end
  end

  @doc """
  One PPDU carrying `psdu` (FCS included) at 8 MS/s, scaled to `@rms`, as
  `{tx1, tx2}` sample pairs. `opts` go to `Ppdu.tx/2`; `:antennas` is
  `:tx1` (default), `:tx2` or `:both` (same samples on both).
  """
  @spec ppdu_8m(binary(), keyword()) :: [{cx(), cx()}]
  def ppdu_8m(psdu, opts \\ []) do
    {ant, opts} = Keyword.pop(opts, :antennas, :tx1)
    x = psdu |> Ppdu.tx(Keyword.put_new(opts, :bw, 2)) |> Map.fetch!(:samples) |> interp4()
    p = Enum.sum(Enum.map(x, &Cx.abs2/1)) / length(x)
    x = Enum.map(x, &Cx.scale(&1, @rms / :math.sqrt(p)))
    z = Cx.zero()

    case ant do
      :tx1 -> Enum.map(x, &{&1, z})
      :tx2 -> Enum.map(x, &{z, &1})
      :both -> Enum.map(x, &{&1, &1})
    end
  end

  @doc """
  1 MB ring image with `copies` (default 4) evenly spaced PPDUs carrying
  `psdu`, silence between. At 8 MS/s the ring period is 16.384 ms.
  """
  @spec ring_image(binary(), keyword()) :: binary()
  def ring_image(psdu, opts \\ []) do
    {copies, opts} = Keyword.pop(opts, :copies, 4)
    frame = ppdu_8m(psdu, opts)
    slot = div(@ring_frames, copies)

    if length(frame) > slot do
      raise ArgumentError,
            "PPDU of #{length(frame)} frames does not fit #{copies} copies (#{slot} each)"
    end

    one = frame |> Enum.map(&word/1) |> IO.iodata_to_binary()
    gap = :binary.copy(<<0::64>>, slot - length(frame))
    tail = :binary.copy(<<0::64>>, @ring_frames - copies * slot)
    IO.iodata_to_binary([List.duplicate([one, gap], copies), tail])
  end

  @doc "Ring words (u64 little-endian binary) -> `[{ch1, ch2}]` at 8 MS/s."
  @spec frames(binary()) :: [{cx(), cx()}]
  def frames(bin) do
    for <<w::little-unsigned-64 <- bin>> do
      {{s12(w), s12(w >>> 12)}, {s12(w >>> 24), s12(w >>> 36)}}
    end
  end

  defp word({{i1, q1}, {i2, q2}}) do
    w = q12(i1) ||| q12(q1) <<< 12 ||| q12(i2) <<< 24 ||| q12(q2) <<< 36
    <<w::little-unsigned-64>>
  end

  defp q12(v), do: v |> round() |> max(-2047) |> min(2047) |> band(0xFFF)

  defp s12(w) do
    v = w &&& 0xFFF
    if v >= 0x800, do: v - 0x1000, else: v
  end
end
