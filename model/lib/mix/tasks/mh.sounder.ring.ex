defmodule Mix.Tasks.Mh.Sounder.Ring do
  @shortdoc "Write the 2x2 sounder TX ring image (1 MB, TxLoop.dma_load format)"
  @moduledoc "    mix mh.sounder.ring OUT.bin"
  use Mix.Task

  @impl true
  def run([out]) do
    img = MimoHalow.Model.Sounder.ring_image()
    File.write!(out, img)
    IO.puts("#{out}: #{byte_size(img)} bytes, period #{MimoHalow.Model.Sounder.period()} samples")
  end
end
