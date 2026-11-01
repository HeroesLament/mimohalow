defmodule MimoHalow.HdlTest do
  use ExUnit.Case
  doctest MimoHalow.Hdl

  test "greets the world" do
    assert MimoHalow.Hdl.hello() == :world
  end
end
