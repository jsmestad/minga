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
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "ROADMAP.md",
          "docs/CONFIGURATION.md",
          "docs/ARCHITECTURE.md",
          "docs/DIAGRAMS.md",
          "docs/PERFORMANCE.md",
          "docs/EXTENSIBILITY.md",
          "docs/PROJECTS.md",
          "docs/FOR-NEOVIM-USERS.md",
          "docs/FOR-EMACS-USERS.md",
          "docs/FOR-AI-CODERS.md"
        ],
        groups_for_extras: [
          Guides: [
            "docs/CONFIGURATION.md",
            "docs/ARCHITECTURE.md",
            "docs/DIAGRAMS.md",
            "docs/PERFORMANCE.md",
            "docs/EXTENSIBILITY.md",
            "docs/PROJECTS.md"
          ],
          "Coming From...": [
            "docs/FOR-NEOVIM-USERS.md",
            "docs/FOR-EMACS-USERS.md",
            "docs/FOR-AI-CODERS.md"
          ]
        ],
        before_closing_body_tag: %{
          html: """
          <script defer src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
          <script>
            let initialized = false;
            window.addEventListener("exdoc:loaded", () => {
              if (!initialized) {
                mermaid.initialize({
                  startOnLoad: false,
                  theme: document.body.className.includes("dark") ? "dark" : "default"
                });
                initialized = true;
              }
              let id = 0;
              for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
                const preEl = codeEl.parentElement;
                const graphDefinition = codeEl.textContent;
                const graphEl = document.createElement("div");
                const graphId = "mermaid-graph-" + id++;
                mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
                  graphEl.innerHTML = svg;
                  bindFunctions?.(graphEl);
                  preEl.insertAdjacentElement("afterend", graphEl);
                  preEl.remove();
                });
              }
            });
          </script>
          """
        },
        groups_for_modules: [
          "Public API": [
            Minga.API
          ],
          Editor: [
            Minga.Editor,
            Minga.Editor.Commands,
            Minga.Editor.Viewport,
            Minga.Editor.Window,
            Minga.Editor.WindowTree
          ],
          Buffer: [
            Minga.Buffer.Document,
            Minga.Buffer.Server
          ],
          Modes: [
            Minga.Mode,
            Minga.Mode.Normal,
            Minga.Mode.Insert,
            Minga.Mode.Visual,
            Minga.Mode.Command,
            Minga.Mode.Eval,
            Minga.Mode.OperatorPending,
            Minga.Mode.Replace,
            Minga.Mode.Search
          ],
          Configuration: [
            Minga.Config,
            Minga.Config.Options,
            Minga.Config.Loader,
            Minga.Config.Hooks
          ],
          Themes: [
            Minga.Theme,
            Minga.Theme.DoomOne,
            Minga.Theme.CatppuccinFrappe,
            Minga.Theme.CatppuccinLatte,
            Minga.Theme.CatppuccinMacchiato,
            Minga.Theme.CatppuccinMocha,
            Minga.Theme.OneDark,
            Minga.Theme.OneLight
          ],
          Keymap: [
            Minga.Keymap.Trie,
            Minga.Keymap.Defaults,
            Minga.Keymap.Store,
            Minga.Keymap.KeyParser,
            Minga.WhichKey
          ],
          "Port Protocol": [
            Minga.Port.Protocol,
            Minga.Port.Manager
          ],
          Commands: [
            Minga.Command,
            Minga.Command.Registry,
            Minga.Command.Parser
          ]
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/perf"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Minga.Application, []}
    ]
  end

  defp deps do
    [
      # TODO: revert to {:burrito, "~> 1.6"} once released (fix in ba67b5c)
      {:burrito, github: "burrito-elixir/burrito", branch: "main"},
      {:file_system, "~> 1.0"},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false}
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
      lint: [
        "format --check-formatted",
        "credo --strict",
        "compile --warnings-as-errors",
        "dialyzer"
      ],
      "lint.fix": ["format", "credo --strict"]
    ]
  end
end
