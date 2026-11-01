defmodule MimoHalow.Lab.MixProject do
  use Mix.Project

  # Controller-side bench tooling (sounding the LibreSDR boards over Erlang
  # distribution). Not part of the radio runtime; board/board.exs is compiled
  # on the boards themselves by MimoHalow.Lab.Session.install/1.
  def project do
    [
      app: :mimohalow_lab,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: [{:mimohalow_model, path: "../model"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
