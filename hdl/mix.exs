defmodule MimoHalow.Hdl.MixProject do
  use Mix.Project

  def project do
    [
      app: :mimohalow_hdl,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ehdl, path: "../../ehdl"},
      {:mimohalow_model, path: "../model"}
    ]
  end
end
