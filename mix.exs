defmodule Minga.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :minga,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      compilers: Mix.compilers() ++ [:minga_zig],
      dialyzer: [plt_add_apps: [:mix]],
      releases: releases(),

      # Docs
      name: "Minga",
      source_url: "https://github.com/jsmestad/minga",
      docs: [main: "readme", extras: ["README.md", "PLAN.md"]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Minga.Application, []}
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.5"},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      minga: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: burrito_targets(),
          debug: Mix.env() != :prod,
          no_clean: true
        ]
      ]
    ]
  end

  defp burrito_targets do
    case :os.type() do
      {:unix, :darwin} ->
        [
          macos_aarch64: [os: :darwin, cpu: :aarch64],
          macos_x86_64: [os: :darwin, cpu: :x86_64]
        ]

      {:unix, :linux} ->
        [
          linux_x86_64: [os: :linux, cpu: :x86_64],
          linux_aarch64: [os: :linux, cpu: :aarch64]
        ]

      _ ->
        []
    end
  end

  defp aliases do
    [
      # NOTE: Prefer `bin/minga` which captures the tty device path for the
      # Zig renderer.  `mix minga` works if MINGA_TTY is set manually.
      minga: [
        "run --no-halt --no-start -e 'Application.put_env(:minga, :start_editor, true); Application.ensure_all_started(:minga); Minga.CLI.main(System.argv())'"
      ],
      test: ["test --warnings-as-errors"],
      lint: ["format --check-formatted", "credo --strict", "compile --warnings-as-errors"],
      "lint.fix": ["format", "credo --strict"]
    ]
  end
end
