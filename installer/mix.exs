defmodule MingaNew.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jsmestad/minga"

  def project do
    [
      app: :minga_new,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: false,
      deps: deps(),
      description: "Mix task for generating Minga editor extension projects",
      package: package(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    []
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "templates", "mix.exs", "README.md"]
    ]
  end
end
