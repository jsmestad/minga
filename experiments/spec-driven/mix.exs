defmodule SpecDriven.MixProject do
  use Mix.Project

  def project do
    [
      app: :spec_driven,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SpecDriven.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.6"},
      {:file_system, "~> 1.0"}
    ]
  end
end
