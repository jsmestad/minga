defmodule MingaGhostCursors.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jsmestad/minga"

  def project do
    [
      app: :minga_ghost_cursors,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: false,
      deps: deps(),
      description: "Ghost cursor overlays for Minga agent editing sessions",
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:minga_sdk, path: "../../sdk", runtime: false},
      {:minga, path: "../../", only: :test}
    ]
  end
end
