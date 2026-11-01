defmodule MimoHalow.Hw.Iface.TxAnt do
  @moduledoc """
  MIMO transmit stage output into the (shared) IFFT: the frequency-domain
  value of one subcarrier for one antenna per beat. Provider: the MIMO
  transmit stage.
  """
  use Hw.Interface

  param :w, :pos_integer, default: 16
  param :bin_bits, :pos_integer, default: 6

  signal :valid, 1, :provider_drives
  signal :ready, 1, :consumer_drives
  signal :i, {:param, :w}, :provider_drives
  signal :q, {:param, :w}, :provider_drives
  signal :bin, {:param, :bin_bits}, :provider_drives
  signal :ant, 1, :provider_drives
  signal :last, 1, :provider_drives
end
