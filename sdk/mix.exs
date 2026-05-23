defmodule MingaSdk.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jsmestad/minga"

  def project do
    [
      app: :minga_sdk,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: false,
      deps: deps(),
      description: "Compile-time SDK for building Minga editor extensions",
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "LICENSE"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
