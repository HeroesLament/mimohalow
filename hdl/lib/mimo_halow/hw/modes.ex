defmodule MimoHalow.Hw.Modes do
  @moduledoc """
  The MIMO modes a bitstream can carry. Each mode is a receive component
  (consumes `Iface.Bins`, provides `Iface.Points`) and a transmit component
  (consumes `Iface.TxSyms`, provides `Iface.TxAnt`); the atoms match the
  model's scheme names (`MimoHalow.Model.Mimo.Sim.schemes/0`) and each RTL
  mode has a fixed-point twin of the same name.

  Selection is at elaboration: `config :mimohalow_hdl, modes: [...]` or
  `mix mh.bit --modes eig1,stbc`. Modes not selected are not elaborated and
  cost nothing. With more than one selected, a runtime mode field picks per
  frame, and the capability mask (`mask/1`) goes to the generated regmap.

  Status: `:implemented` (RTL + twin + co-sim), `:twin` (fixed-point twin
  only), `:planned`.
  """

  @modes [
    siso: %{bit: 0, rx: :mrc_combiner, tx: :ant1, status: :planned},
    mrc_1x2: %{bit: 1, rx: :mrc_combiner, tx: :ant1, status: :planned},
    eigen_1ss: %{bit: 2, rx: :mrc_combiner, tx: :v_precoder, status: :planned},
    alamouti: %{bit: 3, rx: :stbc_combiner, tx: :stbc_encoder, status: :planned},
    sm_mmse: %{bit: 4, rx: :mmse_detector, tx: :ant_map, status: :planned},
    svd_2ss: %{bit: 5, rx: :mmse_detector, tx: :v_precoder, status: :planned},
    sm_ml: %{bit: 6, rx: :ml_detector, tx: :ant_map, status: :planned}
  ]

  @default [:eigen_1ss]

  def all, do: Keyword.keys(@modes)
  def info(mode), do: Keyword.fetch!(@modes, mode)

  @doc "Modes selected for this build (application env, default eig1)."
  def selected do
    modes = Application.get_env(:mimohalow_hdl, :modes, @default)
    Enum.each(modes, &info/1)
    modes
  end

  @doc "Distinct receive / transmit blocks the selected modes need."
  def rx_blocks(modes \\ selected()), do: modes |> Enum.map(&info(&1).rx) |> Enum.uniq()
  def tx_blocks(modes \\ selected()), do: modes |> Enum.map(&info(&1).tx) |> Enum.uniq()

  @doc "Capability bitmask for the regmap."
  def mask(modes \\ selected()) do
    Enum.reduce(modes, 0, fn m, acc -> Bitwise.bor(acc, Bitwise.bsl(1, info(m).bit)) end)
  end
end
