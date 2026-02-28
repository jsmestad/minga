defmodule Minga.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :minga,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      compilers: Mix.compilers() ++ [:minga_zig],
      dialyzer: [plt_add_apps: [:mix]],

      # Docs
      name: "Minga",
      source_url: "https://github.com/jsmestad/minga",
      docs: [main: "readme", extras: ["README.md", "PLAN.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Minga.Application, []}
    ]
  end

  defp deps do
    [
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      minga: ["run --no-halt -e 'Minga.CLI.main(System.argv())'"],
      test: ["test --warnings-as-errors"],
      lint: ["format --check-formatted", "credo --strict", "compile --warnings-as-errors"],
      "lint.fix": ["format", "credo --strict"]
    ]
  end
end
