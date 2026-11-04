defmodule MimoHalow.Halowave do
  @moduledoc """
  halowave-rs NIF (radio/native/halowave_nif). Loaded explicitly with
  `load/1` from the cross-built `.so`, not via `@on_load`, so the module
  compiles and loads on hosts without it.
  """

  @default "/data/rns_ebin/libhalowave_nif_v2"

  @doc "Load the NIF from `path` (no `.so` suffix)."
  def load(path \\ @default), do: :erlang.load_nif(String.to_charlist(path), 0)

  @doc "1 MB TX ring image: `{:ok, image, ppdu_frames}` or `{:error, reason}`."
  def one_shot(psdu, mcs, lead, ant \\ :tx1), do: one_shot_nif(psdu, mcs, lead, ant)

  @doc "Packed PPDU frames (8 bytes each), no lead or padding."
  def frames(psdu, mcs, ant \\ :tx1), do: frames_nif(psdu, mcs, ant)

  @doc "frames/3 in PortWire wire order (each 32-bit word big-endian), for TxLoop.dma_write_wire/2."
  def frames_wire(psdu, mcs, ant \\ :tx1), do: frames_wire_nif(psdu, mcs, ant)

  @doc "CTRL3 command words for the PHY's fabric transmitter (PhyHost, \"MHW2\" bitstreams)."
  def fabric_cmds(psdu, mcs), do: fabric_cmds_nif(psdu, mcs)

  @doc "PSDU with the 802.11 CRC-32 FCS appended."
  def with_fcs(b), do: b <> <<:erlang.crc32(b)::little-32>>

  @doc false
  def one_shot_nif(_, _, _, _), do: :erlang.nif_error(:not_loaded)
  @doc false
  def frames_nif(_, _, _), do: :erlang.nif_error(:not_loaded)
  @doc false
  def frames_wire_nif(_, _, _), do: :erlang.nif_error(:not_loaded)
  @doc false
  def fabric_cmds_nif(_, _), do: :erlang.nif_error(:not_loaded)
end
