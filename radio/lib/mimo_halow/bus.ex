defmodule MimoHalow.Bus do
  @moduledoc """
  PL register access, implemented by the board side (nervezynq) or by a model.

  Offsets are byte offsets into the PHY's AXI slave window. Values are 32-bit words.
  """

  @type offset :: non_neg_integer()
  @type word :: 0..0xFFFF_FFFF

  @doc "Read one register."
  @callback read32(offset()) :: word()

  @doc "Write one register."
  @callback write32(offset(), word()) :: :ok

  @doc "Read `count` consecutive words starting at `offset` (memory window, RX ring)."
  @callback read_window(offset(), count :: pos_integer()) :: [word()]

  @doc "Write each word to the same `offset` in order (FIFO port, TX buffer)."
  @callback write_fifo(offset(), [word()]) :: :ok
end
