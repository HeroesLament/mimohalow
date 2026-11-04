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

  # Zero-stuff by 2, then filter with the half-band at a gain of 2, in
  # polyphase form. Both half-bands have an odd centre index c, so on the
  # zero-stuffed stream an odd output i only meets the centre tap (gain
  # 2 * 2^(q-1) / 2^q = 1): y[i] = x[(i - c) / 2]. An even output only meets
  # the even-indexed taps, the half-band's side taps: y[2m] = sum g_k
  # x[m - k/2]. Same terms in the same order as the direct form, without
  # the multiplies by the stuffed zeros. Output length 2n + N - 1.
  defp up2(xs, h, q) do
    n = length(xs)
    nt = length(h)
    c = div(nt - 1, 2)
    1 = rem(c, 2)
    t = List.to_tuple(xs)

    ev =
      for {hk, k} <- Enum.with_index(h),
          hk != 0,
          rem(k, 2) == 0,
          do: {2.0 * hk / (1 <<< q), div(k, 2)}

    d = div(c - 1, 2)
    z = Cx.zero()

    for i <- 0..(2 * n + nt - 2) do
      m = div(i, 2)

      if rem(i, 2) == 1 do
        j = m - d
        if j >= 0 and j < n, do: elem(t, j), else: z
      else
        Enum.reduce(ev, z, fn {g, k2}, {ar, ai} = acc ->
          j = m - k2

          if j >= 0 and j < n do
            {xr, xi} = elem(t, j)
            {ar + g * xr, ai + g * xi}
          else
            acc
          end
        end)
      end
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

    one = pack(frame)
    gap = :binary.copy(<<0::64>>, slot - length(frame))
    tail = :binary.copy(<<0::64>>, @ring_frames - copies * slot)
    IO.iodata_to_binary([List.duplicate([one, gap], copies), tail])
  end

  @doc "`{tx1, tx2}` sample pairs -> ring words (u64 little-endian binary)."
  @spec pack([{cx(), cx()}]) :: binary()
  def pack(frames), do: frames |> Enum.map(&word/1) |> IO.iodata_to_binary()

  @doc """
  1 MB ring image for one transmission: `:lead` zero frames (default 8000),
  one PPDU carrying `psdu`, silence to the end. The lead covers the time
  between the DMA starting at the ring head and the transmitter keying
  (`TxLoop.dma_burst/2` starts the DMA, then moves the ENSM to TX).
  Returns `{image, %{lead: frames, ppdu: frames}}`; at R frames/s the PPDU
  ends (lead + ppdu) / R after the DMA starts.
  """
  @spec one_shot(binary(), keyword()) ::
          {binary(), %{lead: non_neg_integer(), ppdu: pos_integer()}}
  def one_shot(psdu, opts \\ []) do
    {lead, opts} = Keyword.pop(opts, :lead, 8000)
    frame = ppdu_8m(psdu, opts)
    n = length(frame)

    if lead + n > @ring_frames do
      raise ArgumentError, "lead #{lead} + PPDU #{n} frames exceed the ring (#{@ring_frames})"
    end

    img =
      IO.iodata_to_binary([
        :binary.copy(<<0::64>>, lead),
        pack(frame),
        :binary.copy(<<0::64>>, @ring_frames - lead - n)
      ])

    {img, %{lead: lead, ppdu: n}}
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
