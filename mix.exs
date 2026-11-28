Code.require_file("mix/compiler_manifest.ex", __DIR__)

defmodule Minga.MixProject do
  use Mix.Project

  @version "0.1.0"
  @rolling_version_pattern ~r/\A#{Regex.escape(@version)}-dev\.[1-9][0-9]*\z/
  # Compile the shared declarations, not the SDK-only stubs alongside them.
  @elixirc_paths ["generated/elixir", "lib", "sdk/lib/declarations"]
  @native_release_artifacts ~w(minga-renderer-go minga-parser minga-hook-runner minga-shell-output-reader minga-clone-tree minga-lsp-guard)
  @release_priv_entries @native_release_artifacts ++
                          ~w(queries tree_sitter tutor.txt minga-apple-inference)
  @tui_release_files ~w(mix/release_erts.ex mix/tasks/release.tui.ex)

  def project do
    [
      app: :minga,
      version: project_version(Mix.env()),
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: test_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_deps: :apps_direct,
        # Keep the PLT lean for dev/agent loops: include only direct runtime deps by default, then add transitive apps that Minga source references directly.
        plt_add_apps: [
          :llm_db,
          :mix,
          :nimble_options,
          :plug,
          :plug_crypto,
          :thousand_island,
          :websock
        ],
        # dialyxir's :apps_direct walk includes the project app, which put Minga's own ~10K
        # contracts (1.5 GB) into the dependency PLT. Analysis re-derives them anyway (#3869).
        plt_ignore_apps: [:minga],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      consolidate_protocols: Mix.env() != :prod,
      releases: releases(),

      # Docs
      name: "Minga",
      source_url: "https://github.com/jsmestad/minga",
      homepage_url: docs_homepage_url(),
      docs: docs()
    ]
  end

  @spec docs() :: keyword()
  defp docs do
    module_groups = docs_module_groups()

    published_modules =
      module_groups
      |> Keyword.values()
      |> List.flatten()
      |> MapSet.new()

    published_module_names = MapSet.new(published_modules, &inspect/1)

    [
      main: "reference",
      logo: "assets/minga_dark-transparent.svg",
      favicon: "assets/minga_dark-transparent.svg",
      # Extras link to these directories relative to their own page, so each keeps its name in the output.
      assets: %{
        "assets" => "assets",
        "docs/exdoc" => "exdoc",
        "docs/images" => "images",
        "docs/design/marks" => "marks"
      },
      extras: [
        # Start
        {"docs/REFERENCE.md", title: "Reference"},
        {"CHANGELOG.md", title: "Changelog"},
        # Use Minga
        "docs/CONFIGURATION.md",
        "docs/PROJECTS.md",
        "docs/AGENT-MODEL-SELECTION.md",
        # The key reference for today's build. "Keys" in the Design System group is the v0.1.0 target keymap.
        {"docs/AGENTIC-KEYMAP.md", title: "Key reference"},
        # Run Agents Unattended
        "docs/HOOKS.md",
        "docs/MCP.md",
        "docs/REMOTE_AGENTS.md",
        # Extend Minga
        "docs/EXTENSION_API.md",
        # How It Works
        "docs/ARCHITECTURE.md",
        "docs/BUFFER-AWARE-AGENTS.md",
        "docs/SESSION-RECOVERY.md",
        "docs/KEYMAP-SCOPES.md",
        "docs/PROTOCOL.md",
        "docs/GUI_PROTOCOL.md",
        "docs/CHARM_TUI.md",
        # Design System. ExDoc writes every extra to one flat directory, so each page gets a design- prefix.
        {"docs/design/README.md", filename: "design"},
        {"docs/design/principles.md", filename: "design-principles"},
        {"docs/design/marks.md", filename: "design-marks"},
        {"docs/design/themes.md", filename: "design-themes"},
        {"docs/design/keys.md", filename: "design-keys"},
        {"docs/design/surfaces.md", filename: "design-surfaces"},
        {"docs/design/anatomy.md", filename: "design-anatomy"},
        {"docs/design/terminal.md", filename: "design-terminal"},
        {"docs/design/tui.md", filename: "design-tui"},
        {"docs/design/storyboard.md", filename: "design-storyboard"},
        {"docs/design/visual_rubric.md", filename: "design-visual-rubric"},
        # Decisions
        "docs/adr/0001-frontend-owns-row-fit.md",
        "docs/adr/0002-editor-state-transitions-have-explicit-owners.md",
        "docs/adr/0003-extension-code-updates-require-a-new-vm-generation.md",
        "docs/adr/0004-products-are-root-applets-over-a-fixed-engine.md",
        "docs/adr/0005-frontend-owns-immediate-ui-feedback.md",
        "docs/adr/0006-the-spine.md",
        "docs/adr/0007-cua-is-a-key-profile.md",
        "docs/adr/0008-terminal-engine.md",
        "docs/adr/0009-one-modeline-and-window-labels.md"
      ],
      # The sidebar reads in task order. docs/REFERENCE.md lists the same groups, with the Changelog at the end.
      groups_for_extras: [
        Start: [
          "docs/REFERENCE.md",
          "CHANGELOG.md"
        ],
        "Use Minga": [
          "docs/CONFIGURATION.md",
          "docs/PROJECTS.md",
          "docs/AGENT-MODEL-SELECTION.md",
          "docs/AGENTIC-KEYMAP.md"
        ],
        "Run Agents Unattended": [
          "docs/HOOKS.md",
          "docs/MCP.md",
          "docs/REMOTE_AGENTS.md"
        ],
        "Extend Minga": [
          "docs/EXTENSION_API.md"
        ],
        "How It Works": [
          "docs/ARCHITECTURE.md",
          "docs/BUFFER-AWARE-AGENTS.md",
          "docs/SESSION-RECOVERY.md",
          "docs/KEYMAP-SCOPES.md",
          "docs/PROTOCOL.md",
          "docs/GUI_PROTOCOL.md",
          "docs/CHARM_TUI.md"
        ],
        "Design System": [
          "docs/design/README.md",
          "docs/design/principles.md",
          "docs/design/marks.md",
          "docs/design/themes.md",
          "docs/design/keys.md",
          "docs/design/surfaces.md",
          "docs/design/anatomy.md",
          "docs/design/terminal.md",
          "docs/design/tui.md",
          "docs/design/storyboard.md",
          "docs/design/visual_rubric.md"
        ],
        Decisions: [
          "docs/adr/0001-frontend-owns-row-fit.md",
          "docs/adr/0002-editor-state-transitions-have-explicit-owners.md",
          "docs/adr/0003-extension-code-updates-require-a-new-vm-generation.md",
          "docs/adr/0004-products-are-root-applets-over-a-fixed-engine.md",
          "docs/adr/0005-frontend-owns-immediate-ui-feedback.md",
          "docs/adr/0006-the-spine.md",
          "docs/adr/0007-cua-is-a-key-profile.md",
          "docs/adr/0008-terminal-engine.md",
          "docs/adr/0009-one-modeline-and-window-labels.md"
        ]
      ],
      before_closing_head_tag: %{
        html: """
        <link rel="stylesheet" href="exdoc/minga-exdoc.css" />
        <script>
          (() => {
            try {
              const saved = window.localStorage.getItem("minga-theme");
              if (saved === "light" || saved === "dark") {
                const raw = window.localStorage.getItem("ex_doc:settings");
                const settings = raw ? JSON.parse(raw) : {};
                settings.theme = saved;
                window.localStorage.setItem("ex_doc:settings", JSON.stringify(settings));
                document.documentElement.setAttribute("data-theme", saved);
              }
            } catch (_) {}
          })();
        </script>
        """
      },
      before_closing_body_tag: %{
        html:
          docs_topbar_html() <>
            """
            <script defer src="exdoc/minga-exdoc.js"></script>
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
      filter_modules: fn mod, _meta -> MapSet.member?(published_modules, mod) end,
      skip_code_autolink_to: &internal_module_reference?(&1, published_module_names),
      groups_for_modules: module_groups
    ]
  end

  @spec docs_topbar_html() :: String.t()
  defp docs_topbar_html do
    prefix =
      case docs_homepage_url() do
        "/" -> ""
        url when is_binary(url) -> String.trim_trailing(url, "/")
        _ -> "https://mingacode.dev"
      end

    home_href = if prefix == "", do: "/", else: prefix
    docs_href = if prefix == "", do: "/docs/", else: "reference.html"

    """
    <header id="minga-topbar" class="minga-topbar">
      <div class="minga-topbar-inner">
        <a class="minga-brand" href="#{home_href}">
          <img src="assets/minga_dark-transparent.svg" alt="Minga logo" width="24" height="24" />
          <span class="minga-brand-wordmark">minga</span>
          <span class="minga-brand-version">/ v0.1.0-pre</span>
        </a>
        <nav class="minga-nav" id="minga-topbar-nav" aria-label="Primary">
          <a href="#{prefix}/getting-started">Get Started</a>
          <a href="#{prefix}/why-minga">Why Minga</a>
          <a href="#{prefix}/learn/">Learn</a>
          <a href="#{prefix}/architecture">Architecture</a>
          <a href="#{prefix}/extending">Extending</a>
          <a href="#{docs_href}" aria-current="page">Reference</a>
          <a href="https://github.com/jsmestad/minga">GitHub</a>
        </nav>
        <div class="minga-topbar-controls">
          <button type="button" class="minga-theme-btn" data-minga-theme-toggle aria-label="Toggle color theme">Light</button>
          <button type="button" class="minga-nav-btn" data-minga-nav-toggle aria-expanded="false" aria-controls="minga-topbar-nav" aria-label="Toggle navigation menu">Menu</button>
        </div>
      </div>
    </header>
    """
  end

  @spec internal_module_reference?(String.t(), MapSet.t(String.t())) :: boolean()
  defp internal_module_reference?(ref, published_module_names) do
    cleaned = Regex.replace(~r/^(?:t|c|m):/, ref, "")

    case Regex.run(~r/^(Minga(?:Agent|Editor)?(?:\.[A-Z][A-Za-z0-9_]*)*)/, cleaned) do
      [_, module_name] -> not MapSet.member?(published_module_names, module_name)
      _ -> false
    end
  end

  @spec docs_module_groups() :: [{atom(), [module()]}]
  defp docs_module_groups do
    [
      "Configuration & Scripting": [
        Minga.Config,
        Minga.Config.Options,
        Minga.Config.Hooks,
        Minga.Config.Advice,
        Minga.API,
        Minga.Buffer,
        Minga.Events
      ],
      "Extensions & Languages": [
        Minga.Extension,
        Minga.Extension.Editor,
        Minga.Extension.Agent,
        Minga.Extension.AgentAPI,
        Minga.Language,
        Minga.Command,
        Minga.Keymap.Scope
      ],
      "Agent Runtime": [
        MingaAgent.Runtime,
        MingaAgent.Introspection,
        MingaAgent.Tool.Spec,
        MingaAgent.Tool.Context
      ]
    ]
  end

  @spec docs_homepage_url() :: String.t() | nil
  defp docs_homepage_url do
    case System.get_env("MINGA_SITE_URL") do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  @spec project_version(atom()) :: String.t()
  defp project_version(:prod) do
    case System.get_env("MINGA_ROLLING_VERSION") do
      nil ->
        @version

      version ->
        if Regex.match?(@rolling_version_pattern, version) do
          version
        else
          Mix.raise("MINGA_ROLLING_VERSION must be #{@version}-dev.N with a positive decimal N")
        end
    end
  end

  defp project_version(_env), do: @version

  defp elixirc_paths(:test), do: @elixirc_paths ++ ["test/support", "test/perf"]
  defp elixirc_paths(_), do: @elixirc_paths

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
      {:file_system, "~> 1.0"},
      {:stream_data, "~> 1.0", only: :test},
      {:propcheck, "~> 1.5", only: :test},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:req_llm, "~> 1.31"},
      {:jsv, "~> 0.28.0"},
      {:req, "~> 0.7.5"},
      {:vibe_kit, "~> 0.1.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.1", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:hammox, "~> 1.0", only: :test},
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
      minga: [
        include_erts: &tui_release_erts_path!/0,
        steps: [
          &Mix.Tasks.Release.Tui.verify_otp_apps!/1,
          &clean_release/1,
          :assemble,
          &prepare_release_artifacts/1,
          &install_tui_launcher/1
        ]
      ],
      # macOS GUI release: plain OTP release embedded inside Minga.app bundle.
      # Produces a self-contained BEAM release with ERTS included.
      # Use `mix release minga_macos` then `mix app.assemble` to build the bundle.
      minga_macos: [
        include_erts: true,
        cookie: "minga_app_cookie",
        steps: [&clean_release/1, :assemble, &prepare_release_artifacts/1],
        rel_templates_path: "rel",
        strip_beams: Mix.env() == :prod
      ]
    ]
  end

  @spec tui_release_erts_path!() :: Path.t()
  defp tui_release_erts_path! do
    Enum.each(@tui_release_files, &Code.require_file(&1, __DIR__))
    apply(Mix.Tasks.Release.Tui, :erts_path!, [])
  end

  @spec install_tui_launcher(Mix.Release.t()) :: Mix.Release.t()
  defp install_tui_launcher(release) do
    destination = Path.join(release.path, "launchers/minga")
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(Path.join(__DIR__, "macos/Resources/bin/minga-tui"), destination)
    File.chmod!(destination, 0o755)
    release
  end

  @spec clean_release(Mix.Release.t()) :: Mix.Release.t()
  defp clean_release(release) do
    build_path = Path.expand(Mix.Project.build_path())
    relative_path = Path.relative_to(Path.expand(release.path), build_path)

    if relative_path in [".", ".."] or Path.type(relative_path) == :absolute or
         String.starts_with?(relative_path, "../") do
      Mix.raise("Release output must be inside #{build_path}; refusing to clean #{release.path}")
    end

    # --overwrite replaces current versions but leaves obsolete versions alongside them.
    File.mkdir_p!(release.path)

    for entry <- File.ls!(release.path),
        entry in ~w(bin launchers lib releases) or String.starts_with?(entry, "erts-") do
      File.rm_rf!(Path.join(release.path, entry))
    end

    release
  end

  @spec prepare_release_artifacts(Mix.Release.t()) :: Mix.Release.t()
  defp prepare_release_artifacts(release) do
    version = release.applications |> Map.fetch!(:minga) |> Keyword.fetch!(:vsn)
    priv_dir = Path.join([release.path, "lib", "minga-#{version}", "priv"])
    missing = Enum.reject(@native_release_artifacts, &File.regular?(Path.join(priv_dir, &1)))

    if missing != [] do
      Mix.raise("""
      Missing native release artifacts: #{Enum.join(missing, ", ")}
      Run `MIX_ENV=prod mix native.build.tui` before `mix release #{release.name}`.
      """)
    end

    # Mix copies all of the development priv directory. Filter the release copy only.
    for entry <- File.ls!(priv_dir), entry not in @release_priv_entries do
      File.rm_rf!(Path.join(priv_dir, entry))
    end

    # file_system ships its Windows watcher in every Hex package, but these releases target macOS and Linux.
    watcher_version = release.applications |> Map.fetch!(:file_system) |> Keyword.fetch!(:vsn)
    windows_watcher = "lib/file_system-#{watcher_version}/priv/inotifywait.exe"
    File.rm_rf!(Path.join(release.path, windows_watcher))

    release
  end

  defp aliases do
    [
      # Source launchers prepare the profile environment first; see Minga.CLI.source_profile_env?/1.
      minga: [
        "run --no-halt --no-start -e '
          unless Minga.CLI.source_profile_env?(System.get_env()), do: Mix.raise(\"Launch the source editor with bin/minga\")
          argv = System.argv()
          case Minga.CLI.info_flag_output(argv) do
            {:ok, output} ->
              IO.puts(output)
              System.halt(0)
            :none ->
              Minga.SafeMode.put(Minga.CLI.safe_args?(argv))
              unless Minga.CLI.terminal_command_args?(argv), do: Application.put_env(:minga, :start_editor, true)
              if System.get_env(\"MINGA_GUI_RENDERER\"), do: Application.put_env(:minga, :backend, :gui)
              if System.get_env(\"MINGA_PORT_MODE\") == \"connected\", do: Minga.LoggerHandler.install()
              Minga.CLI.prepare_startup(argv, Minga.CLI.terminal_launch())
              # The launch is recorded. No child process inherits the directory a launcher recorded for this start.
              System.delete_env(\"MINGA_LAUNCH_DIR\")
              Application.ensure_all_started(:minga)
              Minga.CLI.main(argv)
          end
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
      "lint.fix": ["format", "credo --strict"],
      ci: [
        "native.build.support",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "cmd env MIX_ENV=test mix test --max-cases 4 --timeout 120000",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ] ++ build_aliases()
  end

  # These tools must work before Minga is compiled, but only load when invoked.
  defp build_aliases do
    protocol = ~w(mix/protocol_generator.ex)
    language = ~w(mix/language_alias_generator.ex)
    zig = ~w(mix/compilers/minga_zig.ex)
    go = ~w(mix/compilers/minga_go_tui.ex)
    native = ~w(mix/tasks/native_build/result.ex)
    apple = ~w(mix/tasks/native_build_apple.ex)
    dialyzer = ~w(mix/tasks/dialyzer.incremental.runner.ex mix/tasks/dialyzer.incremental.ex)

    [
      "app.assemble": build_task(Mix.Tasks.App.Assemble, ~w(mix/tasks/app.assemble.ex)),
      codegen: [
        "deps.loadpaths",
        build_task(
          Mix.Tasks.Codegen,
          protocol ++ language ++ ~w(mix/design_token_generator.ex mix/tasks/codegen.ex)
        )
      ],
      "protocol.gen": [
        "deps.loadpaths",
        build_task(Mix.Tasks.Protocol.Gen, protocol ++ ~w(mix/tasks/protocol.gen.ex))
      ],
      "language_aliases.gen":
        build_task(
          Mix.Tasks.LanguageAliases.Gen,
          language ++ ~w(mix/tasks/language_aliases.gen.ex)
        ),
      "compile.minga_zig": build_task(Mix.Tasks.Compile.MingaZig, zig),
      "compile.minga_go_tui": build_task(Mix.Tasks.Compile.MingaGoTui, go),
      "native.build.apple": build_task(Mix.Tasks.Native.Build.Apple, apple),
      "native.build.support":
        build_task(
          Mix.Tasks.Native.Build.Support,
          native ++ zig ++ apple ++ ~w(mix/tasks/native_build_support.ex)
        ),
      "native.build.go_tui":
        build_task(
          Mix.Tasks.Native.Build.GoTui,
          native ++ go ++ ~w(mix/tasks/native_build_go_tui.ex)
        ),
      "native.build.tui":
        build_task(
          Mix.Tasks.Native.Build.Tui,
          native ++ zig ++ go ++ apple ++ ~w(mix/tasks/native_build_tui.ex)
        ),
      "release.tui": build_task(Mix.Tasks.Release.Tui, @tui_release_files),
      "dialyzer.incremental": [
        "deps.loadpaths",
        build_task(Mix.Tasks.Dialyzer.Incremental, dialyzer)
      ],
      "dialyzer.incremental.clean":
        build_task(
          Mix.Tasks.Dialyzer.Incremental.Clean,
          dialyzer ++ ~w(mix/tasks/dialyzer.incremental.clean.ex)
        )
    ]
  end

  defp build_task(module, paths) do
    fn args ->
      Enum.each(paths, &Code.require_file(&1, __DIR__))
      module.run(args)
    end
  end
end
