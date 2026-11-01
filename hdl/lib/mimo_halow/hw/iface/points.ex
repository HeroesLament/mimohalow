defmodule MimoHalow.Hw.Iface.Points do
  @moduledoc """
  MIMO receive stage output into the demapper: per data subcarrier and
  stream, the division-free equalised point `D` (`i`, `q`) and its gain `G`
  (`g`), so x = D / G and the noise variance is sigma^2 / G. The OcuSync
  `Hw.Equalizer` output, generalised with a stream index; every MIMO mode
  emits this. Provider: the MIMO receive stage.
  """
  use Hw.Interface

  param :w, :pos_integer, default: 26
  param :g_bits, :pos_integer, default: 20
  param :d_bits, :pos_integer, default: 6
  param :j_bits, :pos_integer, default: 11

  signal :valid, 1, :provider_drives
  signal :i, {:param, :w}, :provider_drives
  signal :q, {:param, :w}, :provider_drives
  signal :g, {:param, :g_bits}, :provider_drives
  signal :d, {:param, :d_bits}, :provider_drives
  signal :j, {:param, :j_bits}, :provider_drives
  signal :stream, 1, :provider_drives
  signal :last, 1, :provider_drives
  signal :scale, 4, :provider_drives
  signal :noise, 42, :provider_drives
end
