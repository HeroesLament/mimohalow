defmodule MimoHalow.Designs.LibreSDR.TopTest do
  @moduledoc "The board top elaborates and emits with the mimohalow PHY in its slot."
  use ExUnit.Case

  test "LibreSDR top elaborates and emits Verilog" do
    v = Hw.emit(Hw.Compile.Elaborate.elaborate(MimoHalow.Designs.LibreSDR.Top))
    assert v =~ "module "
    # The PHY's decimator and receiver are in the netlist.
    assert v =~ "phy_dec_"
    assert v =~ "phy_rxp_"
  end
end
