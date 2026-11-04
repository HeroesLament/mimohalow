defmodule MimoHalow.RxRing do
  @moduledoc """
  Decoder for the PHY's RX ring (memory window at 0x10000).

  Window words: 0 "MHW1", 1 write count, 2 {sync, drop}, 3 {det, flags},
  4 {preempt}. Ring of #{2048} words from word 2048, written cyclically.
  Entries:

    * SIG   `{0, 3'd1, ok[27], discard[26], mcs[25:22], aggr[21], length[19:11], ndata[10:0]}`
    * BYTES `{1, last[30], n[29:28], b2[23:16], b1[15:8], b0[7:0]}`

  `feed/2` is incremental: a frame split across two reads is completed by the
  next call. A gap in the write count (ring overrun) drops the frame in
  progress.
  """
  import Bitwise

  @ring_words 2048
  def ring_words, do: @ring_words

  defstruct wc: nil, cur: nil, lost: 0

  @type sig :: %{ok: 0 | 1, discard: 0 | 1, mcs: 0..15, aggr: 0 | 1, length: non_neg_integer(), ndata: non_neg_integer()}
  @type frame :: %{sig: sig(), psdu: binary(), complete: boolean(), fcs_ok: boolean()}

  @doc "Decode a SIG word."
  def sig(w) do
    %{ok: w >>> 27 &&& 1, discard: w >>> 26 &&& 1, mcs: w >>> 22 &&& 15,
      aggr: w >>> 21 &&& 1, length: w >>> 11 &&& 0x1FF, ndata: w &&& 0x7FF}
  end

  @doc "Ring words (oldest first) -> {state, frames that ended in them}."
  @spec feed(%__MODULE__{}, [non_neg_integer()]) :: {%__MODULE__{}, [frame()]}
  def feed(%__MODULE__{} = st, words) do
    {acc, cur} = Enum.reduce(words, {[], st.cur}, &step/2)
    {%{st | cur: cur}, Enum.reverse(acc)}
  end

  defp step(w, {acc, cur}) do
    cond do
      w >>> 31 == 0 and w >>> 28 == 1 ->
        # A new SIG ends any frame still open (its BYTES were cut short).
        {close(acc, cur, false), %{sig: sig(w), bytes: []}}

      w >>> 31 == 1 and cur != nil ->
        n = w >>> 28 &&& 3
        bs = for i <- 0..(n - 1)//1, do: w >>> (8 * i) &&& 0xFF
        cur = %{cur | bytes: Enum.reverse(bs, cur.bytes)}
        if (w >>> 30 &&& 1) == 1, do: {close(acc, cur, true), nil}, else: {acc, cur}

      true ->
        {acc, cur}
    end
  end

  defp close(acc, nil, _), do: acc

  defp close(acc, %{sig: s, bytes: bs}, complete) do
    psdu = bs |> Enum.reverse() |> :binary.list_to_bin()
    [%{sig: s, psdu: psdu, complete: complete, fcs_ok: complete and fcs_ok?(psdu)} | acc]
  end

  @doc "CRC-32 FCS, appended little-endian (802.11)."
  def fcs_ok?(psdu) when byte_size(psdu) > 4 do
    n = byte_size(psdu) - 4
    <<body::binary-size(n), fcs::little-32>> = psdu
    :erlang.crc32(body) == fcs
  end

  def fcs_ok?(_), do: false

  @doc """
  Ring positions to read for write count `wc` given the last seen count:
  `{lost, [{word_index, count}]}` with at most two spans (wrap).
  """
  def spans(nil, wc), do: {0, span(wc, 0)}

  def spans(last, wc) when wc >= last do
    n = wc - last
    if n > @ring_words, do: {n - @ring_words, span(wc, @ring_words)}, else: {0, span(wc, n)}
  end

  # Write count wrapped at 32 bits.
  def spans(last, wc), do: spans(last - 0x1_0000_0000, wc)

  defp span(_wc, 0), do: []

  defp span(wc, n) do
    start = Integer.mod(wc - n, @ring_words)
    if start + n <= @ring_words,
      do: [{start, n}],
      else: [{start, @ring_words - start}, {0, n - (@ring_words - start)}]
  end
end
