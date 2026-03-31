defmodule Changeset.MixProject do
  use Mix.Project

  def project do
    [
      app: :changeset,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Changeset.Application, []}
    ]
  end

  defp deps do
    []
  end
end
