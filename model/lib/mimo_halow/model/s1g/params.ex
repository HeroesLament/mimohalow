defmodule MimoHalow.Model.S1g.Params do
  @moduledoc """
  S1G PHY constants for the 1 MHz (32-point) and 2 MHz (64-point) channel
  widths, 31.25 kHz subcarrier spacing, 1 spatial stream.

  Sources: the TGah Tx reference code (IEEE 802.11-14/0631r2, compatible
  with 802.11ah Draft 1.1) and, for the 1 MHz LTF, gr-ieee802-11ah
  (validated against Morse Micro captures). The 2 MHz STF/LTF are the
  11n/ac 20 MHz HT-STF and 56-tone HT-LTF. Items to re-check against the
  2016 text: the 1 MHz STF (half amplitude on +-12) and the last SIG fields.

  Tone index `k` runs over -N/2..N/2-1; FFT bin is `rem(k + N, N)`.
  """

  @ltf2 [1, 1, 1, 1, -1, -1, 1, 1, -1, 1, -1, 1, 1, 1, 1, 1, 1, -1, -1, 1, 1, -1, 1, -1, 1, 1, 1, 1, 0,
         1, -1, -1, 1, 1, -1, 1, -1, 1, -1, -1, -1, -1, -1, 1, 1, -1, -1, 1, -1, 1, -1, 1, 1, 1, 1, -1, -1]
  @ltf1 [1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1, 1, 0, -1, -1, -1, 1, -1, -1, -1, 1, -1, 1, 1, 1, -1]

  @c 0.7071067811865476
  @stf2 Map.new(Enum.zip([-24, -20, -16, -12, -8, -4, 4, 8, 12, 16, 20, 24], [1, -1, 1, -1, -1, 1, -1, -1, 1, 1, 1, 1]))
  @stf1 Map.new(Enum.zip([-12, -8, -4, 4, 8, 12], [0.5, -1, 1, -1, -1, -0.5]))

  @s_rep [1, 0, 0, 0, 0, 1, 0, 1, 0, 1, 1, 1]

  # MCS -> {modulation, {rate numerator, denominator}}
  @mcs %{
    0 => {:bpsk, {1, 2}},
    1 => {:qpsk, {1, 2}},
    2 => {:qpsk, {3, 4}},
    3 => {:qam16, {1, 2}},
    4 => {:qam16, {3, 4}},
    5 => {:qam64, {2, 3}},
    6 => {:qam64, {3, 4}},
    7 => {:qam64, {5, 6}},
    8 => {:qam256, {3, 4}},
    9 => {:qam256, {5, 6}},
    10 => {:bpsk, {1, 2}}
  }

  def nfft(1), do: 32
  def nfft(2), do: 64

  def bin(k, bw), do: rem(k + nfft(bw), nfft(bw))

  def pilots(1), do: [-7, 7]
  def pilots(2), do: [-21, -7, 7, 21]

  @doc "Base pilot pattern; data/1 MHz symbols rotate it by the symbol index."
  def pilot_pattern(1), do: [1, -1]
  def pilot_pattern(2), do: [1, 1, 1, -1]

  @doc "Used (LTF) tones."
  def used(1), do: for(k <- -13..13, k != 0, do: k)
  def used(2), do: for(k <- -28..28, k != 0, do: k)

  @doc "Data tones of the data field (and of the 1 MHz SIG)."
  def data(bw), do: for(k <- used(bw), k not in pilots(bw), do: k)

  @doc "Data tones of the 2 MHz SIG (legacy 48-tone layout)."
  def sig_data(2), do: for(k <- -26..26, k != 0, k not in pilots(2), do: k)
  def sig_data(1), do: data(1)

  def ltf(1), do: -13..13 |> Enum.zip(@ltf1) |> Map.new() |> Map.delete(0)
  def ltf(2), do: -28..28 |> Enum.zip(@ltf2) |> Map.new() |> Map.delete(0)

  @doc "STF tone values (complex, before the 1/sqrt(Ntone) normalisation)."
  def stf(1), do: Map.new(@stf1, fn {k, v} -> {k, {v * @c * :math.sqrt(4 / 3), v * @c * :math.sqrt(4 / 3)}} end)
  def stf(2), do: Map.new(@stf2, fn {k, v} -> {k, {v * @c, v * @c}} end)

  @doc "Field normalisations: time = norm * N * ifft(tones)."
  def norm(:stf, 1), do: :math.sqrt(1 / 6)
  def norm(:stf, 2), do: :math.sqrt(1 / 12)
  def norm(:ltf, 1), do: :math.sqrt(1 / 26)
  def norm(:ltf, 2), do: :math.sqrt(1 / 56)
  def norm(:sig, 1), do: :math.sqrt(1 / 26)
  def norm(:sig, 2), do: :math.sqrt(1 / 52)
  def norm(:data, 1), do: :math.sqrt(1 / 26)
  def norm(:data, 2), do: :math.sqrt(1 / 56)

  @doc "MCS10 repetition XOR mask (also the 1 MHz SIG repetition)."
  def s_rep, do: @s_rep

  def mcs(m), do: Map.fetch!(@mcs, m)

  @doc """
  Per-symbol rate parameters for `bw`, `mcs` (1 SS, 1 BCC encoder):
  `%{mod, nbpsc, rate, ncbps, ndbps, rep}` where `ncbps` counts coded bits
  before MCS10 repetition. `{:error, :invalid}` for non-integer Ndbps
  (e.g. 2 MHz MCS9) and MCS10 outside 1 MHz.
  """
  def rate(bw, m) do
    {mod, {rn, rd} = r} = mcs(m)
    nsd = length(data(bw))
    nbpsc = MimoHalow.Model.Qam.nbpsc(mod)
    rep = m == 10
    ncbps = if rep, do: div(nsd * nbpsc, 2), else: nsd * nbpsc

    cond do
      rep and bw != 1 -> {:error, :invalid}
      rem(ncbps * rn, rd) != 0 -> {:error, :invalid}
      true -> {:ok, %{mod: mod, nbpsc: nbpsc, rate: r, ncbps: ncbps, ndbps: div(ncbps * rn, rd), rep: rep}}
    end
  end

  @doc "Interleaver geometry for `bw` data / :sig2 (legacy 2 MHz SIG)."
  def interleaver(1, nbpsc), do: %{ncol: 8, nrow: 3 * nbpsc, nrot: 2}
  def interleaver(2, nbpsc), do: %{ncol: 13, nrow: 4 * nbpsc, nrot: 11}
  def interleaver(:sig2, 1), do: %{ncol: 16, nrow: 3, nrot: 0}

  @doc "SIG symbol count and the pilot polarity offset of the first data symbol."
  def sig_syms(1), do: 6
  def sig_syms(2), do: 2

  @doc "Samples: GI is N/4; LTF1 starts with a double GI."
  def gi(bw), do: div(nfft(bw), 4)
end
