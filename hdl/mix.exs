defmodule MimoHalow.Hdl.MixProject do
  use Mix.Project

  def project do
    [
      app: :mimohalow_hdl,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "designs", "test/support"]
  defp elixirc_paths(_), do: ["lib", "designs"]

  defp deps do
    [
      {:ehdl, path: "../../ehdl"},
      {:mimohalow_model, path: "../model"},
      # OcuSync's receive blocks (StfDetector, LtfSync, SymFeed): S1G 2 MHz
      # short preamble has the 11a L-STF / L-LTF layout, so they are reused as is.
      {:openocusync_hdl, path: "../../openocusync/hdl"}
    ]
  end
end
