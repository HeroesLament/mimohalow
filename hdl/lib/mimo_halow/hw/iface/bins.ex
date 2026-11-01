defmodule MimoHalow.Hw.Iface.Bins do
  @moduledoc """
  FFT output into the MIMO receive stage: one frequency bin per beat, both
  receive chains through the same (time-shared) FFT, tagged by chain.
  Provider: the FFT side. Widths default to the OcuSync `Hw.Fft64` formats.
  """
  use Hw.Interface

  param :w, :pos_integer, default: 26
  param :bin_bits, :pos_integer, default: 6
  param :tag_bits, :pos_integer, default: 12

  signal :valid, 1, :provider_drives
  signal :i, {:param, :w}, :provider_drives
  signal :q, {:param, :w}, :provider_drives
  signal :bin, {:param, :bin_bits}, :provider_drives
  signal :chain, 1, :provider_drives
  signal :tag, {:param, :tag_bits}, :provider_drives
end
