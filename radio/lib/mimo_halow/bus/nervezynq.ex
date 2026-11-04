defmodule MimoHalow.Bus.Nervezynq do
  @moduledoc """
  `MimoHalow.Bus` over `Nervezynq.Fabric` (board side). Offsets are relative
  to the PHY's AXI slave; Fabric addresses are the same byte offsets.
  """
  @behaviour MimoHalow.Bus

  @fz Nervezynq.Fabric

  @impl true
  def read32(off) do
    {:ok, v} = @fz.read32(off)
    v
  end

  @impl true
  def write32(off, v), do: @fz.write32(off, v)

  @impl true
  def read_window(off, n) do
    {:ok, ws} = @fz.read_block(off, n)
    ws
  end

  @impl true
  def write_fifo(off, ws), do: Enum.each(ws, &(:ok = @fz.write32(off, &1)))
end
