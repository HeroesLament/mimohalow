defmodule MimoHalow.Hw.Iface.TxSyms do
  @moduledoc """
  Mapped constellation points into the MIMO transmit stage, one per beat,
  tagged by subcarrier and stream. Provider: the mapper.
  """
  use Hw.Interface

  param :w, :pos_integer, default: 16
  param :bin_bits, :pos_integer, default: 6

  signal :valid, 1, :provider_drives
  signal :ready, 1, :consumer_drives
  signal :i, {:param, :w}, :provider_drives
  signal :q, {:param, :w}, :provider_drives
  signal :bin, {:param, :bin_bits}, :provider_drives
  signal :stream, 1, :provider_drives
  signal :last, 1, :provider_drives
end
