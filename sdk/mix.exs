defmodule MingaSdk.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jsmestad/minga"

  # Defined only by a running Minga editor; the SDK never defines it.
  @host_marker Minga.Extension.Supervisor

  def project do
    [
      app: :minga_sdk,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      elixirc_paths: elixirc_paths(),
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

  # Inside a Minga host VM (for example when the editor installs a Hex extension with
  # Mix.install), the real Minga modules are already loaded. Compiling the SDK's stubs there
  # would replace them, so the SDK compiles nothing in that case.
  @doc false
  def elixirc_paths, do: if(host_vm?(), do: [], else: ["lib"])

  @doc false
  def host_vm?, do: Code.ensure_loaded?(@host_marker)

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/sdk/CHANGELOG.md"
      },
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "main",
      source_url_pattern: "#{@source_url}/blob/main/sdk/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      groups_for_modules: [
        Extension: [
          Minga.Extension,
          Minga.Extension.Agent,
          Minga.Extension.Editor,
          Minga.Extension.Macros,
          Minga.Extension.Manifest,
          Minga.Extension.Storage,
          Minga.Extension.Diagnostics,
          Minga.Extension.Badge,
          Minga.Extension.Overlay,
          Minga.Extension.Panel,
          Minga.Events,
          Minga.Buffer,
          Minga.Buffer.EditDelta,
          Minga.Buffer.EditSource
        ],
        "Model routes": [
          Minga.Extension.ModelRoutes,
          ~r/^MingaAgent\.InferenceRoute/
        ],
        Editor: [~r/^MingaEditor\.Extension/],
        Agent: [Minga.Extension.AgentAPI, Minga.Extension.AI]
      ]
    ]
  end
end
