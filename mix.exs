Code.require_file("mix/protocol_generator.ex", __DIR__)
Code.require_file("mix/language_alias_generator.ex", __DIR__)
Code.require_file("mix/compilers/language_aliases_gen.ex", __DIR__)
Code.require_file("mix/compilers/protocol_gen.ex", __DIR__)
Code.require_file("mix/compilers/minga_bundled_extensions.ex", __DIR__)
Code.require_file("mix/compilers/minga_zig.ex", __DIR__)
Code.require_file("mix/compilers/minga_go_tui.ex", __DIR__)
Code.require_file("mix/tasks/language_aliases.gen.ex", __DIR__)
Code.require_file("mix/tasks/protocol.gen.ex", __DIR__)
Code.require_file("mix/tasks/dialyzer.incremental.runner.ex", __DIR__)
Code.require_file("mix/tasks/dialyzer.incremental.ex", __DIR__)
Code.require_file("mix/tasks/dialyzer.incremental.clean.ex", __DIR__)
Code.require_file("mix/tasks/native_build/result.ex", __DIR__)
Code.require_file("mix/tasks/native_build_support.ex", __DIR__)
Code.require_file("mix/tasks/native_build_tui.ex", __DIR__)
Code.require_file("mix/tasks/native_build_go_tui.ex", __DIR__)

# Burrito hard-codes musl libc for Linux binaries. Tell cc_precompiler to
# fetch the precompiled musl NIF for exqlite instead of source-compiling
# against the host glibc (whose versioned symbols musl cannot resolve).
if Mix.env() == :prod and :os.type() == {:unix, :linux} do
  arch = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()
  System.put_env("TARGET_ARCH", arch)
  System.put_env("TARGET_OS", "linux")
  System.put_env("TARGET_ABI", "musl")
end

defmodule Minga.MixProject do
  use Mix.Project

  @version "0.1.0"
  @generated_language_aliases_path ".generated/language_aliases/elixir/lib"
  @generated_elixir_path ".generated/protocol/elixir/lib"

  def project do
    [
      app: :minga,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: test_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      compilers:
        [:language_aliases_gen, :protocol_gen, :minga_bundled_extensions] ++ Mix.compilers(),
      dialyzer: [
        plt_add_deps: :apps_direct,
        # Keep the PLT lean for dev/agent loops: include only direct runtime deps by default, then add transitive apps that Minga source references directly.
        plt_add_apps: [:llm_db, :mix, :plug, :plug_crypto, :thousand_island, :websock],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      consolidate_protocols: Mix.env() != :prod,
      releases: releases(),

      # Docs
      name: "Minga",
      source_url: "https://github.com/jsmestad/minga",
      docs: [
        main: "readme",
        assets: %{"assets" => "assets"},
        extras: [
          # Overview
          "README.md",
          "CHANGELOG.md",
          # Getting Started
          "docs/GETTING-STARTED.md",
          # Using Minga
          "docs/CONFIGURATION.md",
          "docs/PROJECTS.md",
          # Coming From...
          "docs/FOR-NEOVIM-USERS.md",
          "docs/FOR-EMACS-USERS.md",
          "docs/FOR-AI-CODERS.md",
          # Extending Minga
          "docs/EXTENSIBILITY.md",
          "docs/EXTENSION_API.md",
          "docs/KEYMAP-SCOPES.md",
          "docs/AGENTIC-KEYMAP.md",
          # Architecture
          "docs/ARCHITECTURE.md",
          "docs/PROTOCOL.md",
          "docs/BUFFER-AWARE-AGENTS.md",
          # Development
          "CONTRIBUTING.md",
          "docs/RELEASING.md"
        ],
        groups_for_extras: [
          "Getting Started": [
            "docs/GETTING-STARTED.md"
          ],
          "Using Minga": [
            "docs/CONFIGURATION.md",
            "docs/PROJECTS.md"
          ],
          "Coming From...": [
            "docs/FOR-NEOVIM-USERS.md",
            "docs/FOR-EMACS-USERS.md",
            "docs/FOR-AI-CODERS.md"
          ],
          "Extending Minga": [
            "docs/EXTENSIBILITY.md",
            "docs/EXTENSION_API.md",
            "docs/KEYMAP-SCOPES.md",
            "docs/AGENTIC-KEYMAP.md"
          ],
          Architecture: [
            "docs/ARCHITECTURE.md",
            "docs/PROTOCOL.md",
            "docs/BUFFER-AWARE-AGENTS.md"
          ],
          Development: [
            "CONTRIBUTING.md",
            "docs/RELEASING.md"
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
            MingaEditor,
            MingaEditor.Commands,
            MingaEditor.Viewport,
            MingaEditor.Window,
            MingaEditor.WindowTree
          ],
          Buffer: [
            Minga.Buffer,
            Minga.Buffer.Document,
            Minga.Buffer.Process
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
            MingaEditor.UI.WhichKey
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

  defp elixirc_paths(:test),
    do: [
      @generated_language_aliases_path,
      @generated_elixir_path,
      "lib",
      "test/support",
      "test/perf"
    ]

  defp elixirc_paths(_), do: [@generated_language_aliases_path, @generated_elixir_path, "lib"]

  defp test_paths(_), do: ["test"]

  def cli do
    [
      preferred_envs: [
        "test.llm": :test,
        "test.debug": :test,
        "test.quick": :test,
        "test.heavy": :test,
        conformance: :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [
        :logger,
        # Mix + Hex support for runtime extension installation via Mix.install/2
        :mix,
        :inets,
        :ssl,
        :public_key,
        # OTP build tools that extension deps may need at compile time
        :parsetools,
        :compiler,
        :syntax_tools,
        :xmerl
      ],
      mod: {Minga.Application, []}
    ]
  end

  defp deps do
    [
      # TODO: revert to {:burrito, "~> 1.6"} once burrito-elixir/burrito#225 merges
      {:burrito,
       github: "gilbertwong96/burrito", ref: "37db26f367613669f0a61ef35446480ad0ee23a1"},
      {:file_system, "~> 1.0"},
      {:stream_data, "~> 1.0", only: :test},
      {:propcheck, "~> 1.5", only: :test},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:req_llm, "~> 1.16"},
      {:req, "~> 0.6.2"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.1", only: [:dev, :test], runtime: false},
      {:hammox, "~> 0.7", only: :test},
      {:telemetry, "~> 1.0"},
      {:toml, "~> 0.7.0"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:exqlite, "~> 0.27"},
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"}
    ]
  end

  defp releases do
    [
      # TUI release: Burrito-wrapped standalone binary (macOS + Linux)
      minga: [
        steps: [:assemble, &ensure_tui_release_artifacts/1, &Burrito.wrap/1],
        burrito: [
          targets: burrito_targets(),
          debug: Mix.env() != :prod,
          no_clean: true
        ]
      ],
      # macOS GUI release: plain OTP release embedded inside Minga.app bundle.
      # Produces a self-contained BEAM release with ERTS included.
      # Use `mix release minga_macos` then `mix app.assemble` to build the bundle.
      minga_macos: [
        include_erts: true,
        cookie: "minga_app_cookie",
        steps: [:assemble, &ensure_support_release_artifacts/1],
        rel_templates_path: "rel",
        strip_beams: Mix.env() == :prod
      ]
    ]
  end

  @spec ensure_tui_release_artifacts(Mix.Release.t()) :: Mix.Release.t()
  defp ensure_tui_release_artifacts(release) do
    ensure_release_artifacts!(
      release,
      ["minga-renderer-go", "minga-parser", "minga-hook-runner"],
      "Run `MIX_ENV=prod mix native.build.tui` before `mix release minga`."
    )
  end

  @spec ensure_support_release_artifacts(Mix.Release.t()) :: Mix.Release.t()
  defp ensure_support_release_artifacts(release) do
    ensure_release_artifacts!(
      release,
      ["minga-parser", "minga-hook-runner"],
      "Run `MIX_ENV=prod mix native.build.support` before `mix release minga_macos`."
    )
  end

  @spec ensure_release_artifacts!(Mix.Release.t(), [String.t()], String.t()) :: Mix.Release.t()
  defp ensure_release_artifacts!(release, artifact_names, instruction) do
    priv_dirs = Path.wildcard(Path.join([release.path, "lib", "minga-*", "priv"]))
    missing = missing_release_artifacts(priv_dirs, artifact_names)

    if missing == [] do
      release
    else
      Mix.raise("Missing native release artifacts: #{Enum.join(missing, ", ")}\n#{instruction}")
    end
  end

  @spec missing_release_artifacts([String.t()], [String.t()]) :: [String.t()]
  defp missing_release_artifacts([], artifact_names), do: artifact_names

  defp missing_release_artifacts(priv_dirs, artifact_names) do
    Enum.reject(artifact_names, fn artifact_name ->
      Enum.any?(priv_dirs, fn priv_dir -> File.exists?(Path.join(priv_dir, artifact_name)) end)
    end)
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
        "run --no-halt --no-start -e '
          {gui, argv} = case System.argv() do
            [\"+gui\" | rest] -> {true, rest}
            other -> {false, other}
          end
          terminal_command = Minga.CLI.terminal_command_args?(argv)
          if gui and not terminal_command, do: Application.put_env(:minga, :backend, :gui)
          Minga.SafeMode.put(Minga.CLI.safe_args?(argv))
          if not terminal_command, do: Application.put_env(:minga, :start_editor, true)
          if System.get_env(\"MINGA_PORT_MODE\") == \"connected\", do: Minga.LoggerHandler.install()
          Application.ensure_all_started(:minga)
          Minga.CLI.main(argv)
        '"
      ],
      test: ["test --warnings-as-errors --exclude conformance"],
      "test.llm": [
        "test --warnings-as-errors --formatter Minga.Test.LLMFormatter --max-failures 5 --exclude heavy --exclude conformance"
      ],
      "test.debug": ["test --warnings-as-errors --trace --max-failures 3 --exclude conformance"],
      "test.quick": [
        "test --warnings-as-errors --formatter Minga.Test.LLMFormatter --stale --max-failures 5 --exclude heavy --exclude conformance"
      ],
      "test.heavy": ["test --warnings-as-errors --only heavy --exclude conformance"],
      conformance: [
        "run --no-start -e 'Mix.Tasks.Test.run([\"--warnings-as-errors\", \"--include\", \"conformance\", \"test/conformance/\"])'"
      ],
      # lint runs via Makefile (`make lint`) so all steps run even if one
      # fails. Mix aliases stop on first failure, which skips dialyzer.
      "lint.fix": ["format", "credo --strict"]
    ]
  end
end
