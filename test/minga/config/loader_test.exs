defmodule Minga.Config.LoaderTest do
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  # Not async: these tests reset the shared extension registry, hooks, advice and command registry, and they
  # set Application env. One test changes the VM's working directory to prove that the loader does not read it.
  use ExUnit.Case, async: false

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Config
  alias Minga.Config.Hooks
  alias Minga.Config.Loader
  alias Minga.Config.ModelineSegments
  alias Minga.Config.Options
  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.RootSupervisor
  alias Minga.Extension.RuntimeSupervisor
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Language
  alias Minga.Language.Registry, as: LanguageRegistry
  alias Minga.LSP.ServerConfig
  alias Minga.Tool.Recipe
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry
  alias MingaEditor.UI.Theme

  setup do
    options_server = start_supervised!({Options, name: nil})
    keymap_server = start_supervised!({KeymapActive, name: nil})
    previous_options_server = Process.put(:minga_config_options, options_server)
    previous_keymap_server = Process.put(:minga_config_keymap, keymap_server)

    # Hooks/CommandRegistry/ModelineSegments remain global singletons; ensure
    # they're running but not isolated per test.
    for {mod, _} <- [{Hooks, nil}, {CommandRegistry, nil}, {ModelineSegments, nil}] do
      case mod.start_link() do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> mod.reset()
      end
    end

    on_exit(fn ->
      if is_nil(previous_keymap_server) do
        Process.delete(:minga_config_keymap)
      else
        Process.put(:minga_config_keymap, previous_keymap_server)
      end

      if is_nil(previous_options_server) do
        Process.delete(:minga_config_options)
      else
        Process.put(:minga_config_options, previous_options_server)
      end
    end)

    %{options_server: options_server, keymap_server: keymap_server}
  end

  @spec test_options_server() :: GenServer.server()
  defp test_options_server do
    Process.get(:minga_config_options, Options.default_server())
  end

  describe "loading valid config" do
    test "applies set options from config file" do
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config

        set :tab_width, 4
        set :line_numbers, :relative
        """)

      on_exit(cleanup)

      name = :"loader_valid_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      assert Loader.load_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 4
      assert Options.get(test_options_server(), :line_numbers) == :relative
    end

    test "saved bindings get one install notice per missing extracted extension" do
      ExtRegistry.reset()
      on_exit(&ExtRegistry.reset/0)

      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config

        bind :normal, "SPC k f", :knowledge_map, "Familiarity"
        bind :normal, "SPC k c", :knowledge_briefing, "Briefing"
        bind :normal, "SPC a z", :adversarial_analyze, "Challenge"
        extension :minga_adversarial, git: "https://github.com/jsmestad/minga-adversarial"
        raise "later config error"
        """)

      on_exit(cleanup)
      pid = start_supervised!({Loader, name: nil, config_home: config_home})

      assert Loader.load_error(pid) =~ "later config error"
      assert Loader.config_eval_error(pid) =~ "later config error"

      assert Loader.migration_notice(pid) ==
               ~s(Some configured keybindings need optional extensions. Add to config.exs and restart: extension :minga_knowledge_graph, git: "https://github.com/jsmestad/minga-knowledge-graph")
    end

    test "the retired git porcelain declaration warns and the rest of the config still applies" do
      ExtRegistry.reset()
      on_exit(&ExtRegistry.reset/0)

      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config

        extension :git_porcelain
        set :tab_width, 4
        """)

      on_exit(cleanup)

      name = :"loader_retired_#{System.unique_integer([:positive])}"

      {{:ok, pid}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Loader.start_link(name: name, config_home: config_home)
        end)

      assert Loader.load_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 4
      assert ExtRegistry.all() == []
      assert log =~ "extension :git_porcelain is no longer bundled"

      assert log =~
               ~s(extension :minga_git_extended, git: "https://github.com/jsmestad/minga-git-extended")
    end

    test "loads the built-in MCP extension and mcp_server DSL" do
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config

        extension Minga.Extensions.MCP
        mcp_server "github", command: "npx", args: ["-y", "@modelcontextprotocol/server-github"], env: %{"GITHUB_TOKEN" => "token"}
        """)

      on_exit(cleanup)

      name = :"loader_mcp_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      assert Loader.load_error(pid) == nil
      assert {:ok, entry} = ExtRegistry.get(:minga_mcp)
      assert entry.source == {:module, Minga.Extensions.MCP}
      assert entry.module == Minga.Extensions.MCP

      assert [server] = Options.get(test_options_server(), :agent_mcp_servers)
      server = Map.new(server, fn {key, value} -> {to_string(key), value} end)
      assert Map.get(server, "name") == "github"
      assert Map.get(server, "command") == "npx"
    end
  end

  describe "optional GitExtended" do
    setup do
      previous_load_extensions = Application.get_env(:minga, :load_extensions)
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :load_extensions, true)
      ensure_extension_runtime()

      on_exit(fn ->
        ExtSupervisor.stop_all()
        ExtRegistry.reset()
        restore_application_env(:load_extensions, previous_load_extensions)
      end)

      :ok
    end

    test "a default config does not declare GitExtended or register its commands" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      Minga.Events.subscribe(:extension_deferred_batch_complete)

      pid = start_supervised!({Loader, name: nil, config_home: config_home})

      assert Loader.load_error(pid) == nil
      assert ExtRegistry.get(:minga_git_extended) == :error
      assert ExtRegistry.all() == []
      assert CommandRegistry.lookup(CommandRegistry, :git_status_toggle) == :error
      refute_receive {:minga_event, :extension_deferred_batch_complete, _event}, 500
    end
  end

  @tag :heavy
  test "starts extensions declared in project and after config after all config sources load" do
    {minga_dir, config_home, cleanup} =
      make_config_dir("""
      use Minga.Config

      set :tab_width, 2
      """)

    on_exit(cleanup)

    previous_load_extensions = Application.get_env(:minga, :load_extensions)
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, :load_extensions, true)

    on_exit(fn ->
      case previous_load_extensions do
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        nil -> Application.delete_env(:minga, :load_extensions)
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        value -> Application.put_env(:minga, :load_extensions, value)
      end
    end)

    ensure_extension_runtime()

    on_exit(fn ->
      ExtSupervisor.stop_all()
      ExtRegistry.reset()
    end)

    project_dir =
      Path.join(
        System.tmp_dir!(),
        "minga_project_extensions_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(project_dir)

    project_ext_dir = Path.join(project_dir, "project_ext")
    after_ext_dir = Path.join(project_dir, "after_ext")
    File.mkdir_p!(project_ext_dir)
    File.mkdir_p!(after_ext_dir)

    File.write!(Path.join(project_ext_dir, "project_config_ext.ex"), """
    defmodule Minga.TestExtensions.ProjectConfigExt do
      use Minga.Extension

      @impl true
      def name, do: :project_config_ext

      @impl true
      def description, do: "Project config extension"

      @impl true
      def version, do: "1.0.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end
    """)

    File.write!(Path.join(after_ext_dir, "after_config_ext.ex"), """
    defmodule Minga.TestExtensions.AfterConfigExt do
      use Minga.Extension

      @impl true
      def name, do: :after_config_ext

      @impl true
      def description, do: "After config extension"

      @impl true
      def version, do: "1.0.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end
    """)

    File.write!(Path.join(project_dir, ".minga.exs"), """
    use Minga.Config

    extension :project_config_ext, path: #{inspect(project_ext_dir)}
    """)

    File.write!(Path.join(minga_dir, "after.exs"), """
    use Minga.Config

    extension :after_config_ext, path: #{inspect(after_ext_dir)}
    """)

    on_exit(fn ->
      File.rm_rf!(project_dir)
      :code.purge(Minga.TestExtensions.ProjectConfigExt)
      :code.delete(Minga.TestExtensions.ProjectConfigExt)
      :code.purge(Minga.TestExtensions.AfterConfigExt)
      :code.delete(Minga.TestExtensions.AfterConfigExt)
    end)

    name = :"loader_project_after_ext_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

    assert Loader.load_error(pid) == nil
    assert {:ok, project_entry} = ExtRegistry.get(:project_config_ext)
    assert project_entry.status == :running
    assert Process.alive?(project_entry.pid)
    assert {:ok, after_entry} = ExtRegistry.get(:after_config_ext)
    assert after_entry.status == :running
    assert Process.alive?(after_entry.pid)

    on_exit(fn ->
      :ok =
        ExtSupervisor.stop_extension(
          Minga.Extension.Supervisor,
          Minga.Extension.Registry,
          :project_config_ext,
          project_entry
        )

      :ok =
        ExtSupervisor.stop_extension(
          Minga.Extension.Supervisor,
          Minga.Extension.Registry,
          :after_config_ext,
          after_entry
        )
    end)
  end

  describe "loading LSP settings" do
    test "deep-merges user lsp_settings with server defaults" do
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config

        lsp_settings :mock_lsp,
          mock_lsp: [nested: [enabled: false], extra: true]
        """)

      on_exit(cleanup)

      name = :"loader_lsp_settings_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      server_config = %ServerConfig{
        name: :mock_lsp,
        command: "mock-lsp",
        settings: %{
          "mock_lsp" => %{
            "nested" => %{"enabled" => true, "default" => 1},
            "value" => 2
          }
        }
      }

      assert Loader.lsp_settings(pid) == %{
               mock_lsp: %{
                 "mock_lsp" => %{"nested" => %{"enabled" => false}, "extra" => true}
               }
             }

      assert Config.get_lsp_settings(server_config, pid) == %{
               "mock_lsp" => %{
                 "nested" => %{"enabled" => false, "default" => 1},
                 "value" => 2,
                 "extra" => true
               }
             }
    end

    test "supports exact LSP section keys with punctuation" do
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config

        lsp_settings :rust_analyzer, %{
          "rust-analyzer" => %{"cargo" => %{"allFeatures" => false}}
        }
        """)

      on_exit(cleanup)

      name = :"loader_lsp_section_keys_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      server_config = %ServerConfig{
        name: :rust_analyzer,
        command: "rust-analyzer",
        settings: %{
          "rust-analyzer" => %{
            "cargo" => %{"allFeatures" => true},
            "procMacro" => %{"enable" => true}
          }
        }
      }

      assert Config.get_lsp_settings(server_config, pid) == %{
               "rust-analyzer" => %{
                 "cargo" => %{"allFeatures" => false},
                 "procMacro" => %{"enable" => true}
               }
             }
    end

    test "preserves empty list setting values" do
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config

        lsp_settings :mock_lsp, features: []
        """)

      on_exit(cleanup)

      name = :"loader_lsp_empty_list_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      server_config = %ServerConfig{name: :mock_lsp, command: "mock-lsp"}

      assert Config.get_lsp_settings(server_config, pid) == %{"features" => []}
    end
  end

  describe "loading invalid config" do
    test "captures syntax, option validation, and migration errors" do
      cases = [
        {"syntax",
         """
         this is not valid elixir %%%
         """, {:any, ["syntax", "error", "Error"]}},
        {"runtime",
         """
         use Minga.Config

         set :tab_width, -1
         """, {:any, ["positive integer", "error", "Error"]}},
        {"legacy_provider",
         """
         use Minga.Config

         set :agent_provider, :pi_rpc
         """, {:all, ["agent_provider no longer supports :pi_rpc", "Use :native instead"]}}
      ]

      for {label, config, expected_fragments} <- cases do
        {_dir, config_home, cleanup} = make_config_dir(config)

        try do
          name = :"loader_#{label}_#{System.unique_integer([:positive])}"
          {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

          error = Loader.load_error(pid)
          assert is_binary(error)
          assert_error_fragments(error, expected_fragments)
        after
          cleanup.()
        end
      end
    end
  end

  describe "missing config file" do
    test "no error when config file does not exist" do
      empty_dir =
        Path.join(System.tmp_dir!(), "minga_empty_#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty_dir)

      on_exit(fn ->
        File.rm_rf!(empty_dir)
      end)

      name = :"loader_missing_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: empty_dir)

      assert Loader.load_error(pid) == nil
    end
  end

  describe "user module compilation" do
    test "compiles valid modules from the modules directory" do
      {minga_dir, config_home, cleanup} = make_config_dir("")
      modules_dir = Path.join(minga_dir, "modules")
      File.mkdir_p!(modules_dir)

      File.write!(Path.join(modules_dir, "greeter.ex"), """
      defmodule Minga.UserModules.Greeter do
        def hello, do: "world"
      end
      """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.UserModules.Greeter)
        :code.delete(Minga.UserModules.Greeter)
      end)

      name = :"loader_modules_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      assert Minga.UserModules.Greeter in Loader.loaded_modules(pid)
      assert apply(Minga.UserModules.Greeter, :hello, []) == "world"
      assert Loader.modules_errors(pid) == []
    end

    test "preserves module batch and error order while compiling past failures" do
      {minga_dir, config_home, cleanup} = make_config_dir("")
      modules_dir = Path.join(minga_dir, "modules")
      File.mkdir_p!(modules_dir)

      pair_path = Path.join(modules_dir, "10_pair.ex")
      syntax_path = Path.join(modules_dir, "20_syntax.ex")
      raise_path = Path.join(modules_dir, "30_raise.ex")
      consumer_path = Path.join(modules_dir, "40_consumer.ex")

      # Code.compile_file/1 returns the two sibling modules in definition order.
      expected_modules = [
        Minga.UserModules.BatchZulu,
        Minga.UserModules.BatchAlpha,
        Minga.UserModules.BatchConsumer
      ]

      on_exit(fn ->
        cleanup.()

        for module <- expected_modules do
          :code.purge(module)
          :code.delete(module)
        end
      end)

      # Create the files out of order; the consumer needs the pair at compile time.
      File.write!(consumer_path, """
      defmodule Minga.UserModules.BatchConsumer do
        @value Minga.UserModules.BatchZulu.value()
        def value, do: @value
      end
      """)

      File.write!(raise_path, "raise \"fixture failure\"\n")
      File.write!(syntax_path, "defmodule Minga.UserModules.BatchIncomplete do\n")

      File.write!(pair_path, """
      defmodule Minga.UserModules.BatchZulu do
        def value, do: 42
      end

      defmodule Minga.UserModules.BatchAlpha do
      end
      """)

      name = :"loader_mixed_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      assert Loader.loaded_modules(pid) == expected_modules
      assert apply(Minga.UserModules.BatchConsumer, :value, []) == 42

      assert [syntax_error, raise_error] = Loader.modules_errors(pid)
      assert String.starts_with?(syntax_error, "Module compile error in #{syntax_path}: ")
      assert raise_error == "Module error in #{raise_path}: fixture failure"
    end

    test "no error when modules directory does not exist" do
      {_dir, config_home, cleanup} = make_config_dir("")
      on_exit(cleanup)

      name = :"loader_no_modules_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      assert Loader.loaded_modules(pid) == []
      assert Loader.modules_errors(pid) == []
    end
  end

  describe "project-local config" do
    test ".minga.exs in cwd overrides global settings" do
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      # Create .minga.exs in a temp dir and cd into it
      project_dir =
        Path.join(System.tmp_dir!(), "minga_proj_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      File.write!(Path.join(project_dir, ".minga.exs"), """
      use Minga.Config
      set :tab_width, 8
      """)

      on_exit(fn ->
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_project_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

      assert Loader.project_config_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 8
    end

    test "loads project-local .minga/mcp.json" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")

      project_dir =
        Path.join(System.tmp_dir!(), "minga_mcp_json_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(project_dir, ".minga"))

      File.write!(
        Path.join([project_dir, ".minga", "mcp.json"]),
        ~s({"mcpServers":{"github":{"command":"sh","args":["-y","@modelcontextprotocol/server-github"],"env":{"GITHUB_TOKEN":"token"}}}})
      )

      on_exit(fn ->
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_project_mcp_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

      assert Loader.load_error(pid) == nil
      assert [server] = Options.get(test_options_server(), :agent_mcp_servers)
      server = Map.new(server, fn {key, value} -> {to_string(key), value} end)
      assert Map.get(server, "name") == "github"

      # A bare name is found on PATH when the server starts, and the server starts in the project.
      assert Map.get(server, "command") == "sh"
      assert Map.get(server, "args") == ["-y", "@modelcontextprotocol/server-github"]
      {:ok, canonical} = Minga.Project.Root.canonical_path(project_dir)
      assert Map.get(server, "cwd") == canonical
    end

    test "reports a clear error when mcpServers contains a non-map value" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")

      project_dir =
        Path.join(System.tmp_dir!(), "minga_mcp_json_bad_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(project_dir, ".minga"))

      File.write!(
        Path.join([project_dir, ".minga", "mcp.json"]),
        ~s({"mcpServers":{"github":42}})
      )

      on_exit(fn ->
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_project_mcp_bad_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

      assert Loader.load_error(pid) =~ ".minga/mcp.json mcpServers.github must be a map, got: 42"
      # The global config evaluated: a bad project MCP file does not leave the editor on defaults.
      assert Loader.config_eval_error(pid) == nil
      assert Options.get(test_options_server(), :agent_mcp_servers) == []
    end

    test "no error when .minga.exs does not exist" do
      {_dir, config_home, cleanup} = make_config_dir("")

      # Use a temp dir with no .minga.exs
      project_dir =
        Path.join(System.tmp_dir!(), "minga_noproj_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      on_exit(fn ->
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_noproj_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

      assert Loader.project_config_error(pid) == nil
    end
  end

  describe "where project-local config comes from" do
    # These tests register plugins and extensions to see whether a folder's config was read. The registry is
    # shared, so each test starts from an empty one, and nothing is started: registration is the mark.
    setup do
      ensure_extension_runtime()
      previous = Application.get_env(:minga, :load_extensions)
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :load_extensions, false)

      on_exit(fn ->
        restore_application_env(:load_extensions, previous)
        if Process.whereis(ExtRegistry), do: ExtRegistry.reset()
      end)

      :ok
    end

    # A folder that holds every kind of project-local configuration, each of which leaves a mark if it is read.
    defp project_with_everything(label) do
      root = Path.join(System.tmp_dir!(), "minga_#{label}_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, ".minga", "plugins", "marker_plugin"]))
      File.write!(Path.join(root, ".minga.exs"), "use Minga.Config\nset :tab_width, 8\n")

      File.write!(
        Path.join([root, ".minga", "mcp.json"]),
        ~s({"mcpServers":{"marker":{"command":"true"}}})
      )

      on_exit(fn -> File.rm_rf!(root) end)
      root
    end

    defp start_loader(config_home, project_root) do
      name = :"loader_root_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_root)

      pid
    end

    defp nothing_project_local_loaded? do
      Options.get(test_options_server(), :tab_width) != 8 and
        Options.get(test_options_server(), :agent_mcp_servers) == [] and
        ExtRegistry.get(:marker_plugin) == :error
    end

    test "the project's own files load, and the report names the folder and the files" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = project_with_everything("project")
      {:ok, canonical} = Minga.Project.Root.canonical_path(root)

      pid = start_loader(config_home, root)

      assert Options.get(test_options_server(), :tab_width) == 8
      assert [_marker] = Options.get(test_options_server(), :agent_mcp_servers)
      assert {:ok, _plugin} = ExtRegistry.get(:marker_plugin)

      assert {:loaded, ^canonical, files, []} = Loader.project_config(pid)

      assert Enum.map(files, &Path.relative_to(&1, canonical)) ==
               [".minga.exs", ".minga/mcp.json", ".minga/plugins"]

      assert Loader.project_config_message(Loader.project_config(pid)) ==
               "Project config loaded from #{Minga.Project.collapse_home(canonical)}: " <>
                 ".minga.exs, .minga/mcp.json, .minga/plugins."
    end

    test "the directory the VM runs in is not read when the project is elsewhere" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      launch_directory = project_with_everything("launch_dir")
      project = Path.join(System.tmp_dir!(), "minga_empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(project)
      {:ok, canonical} = Minga.Project.Root.canonical_path(project)
      previous = File.cwd!()
      File.cd!(launch_directory)

      on_exit(fn ->
        File.cd!(previous)
        cleanup.()
        File.rm_rf!(project)
      end)

      pid = start_loader(config_home, project)

      assert nothing_project_local_loaded?()
      assert Loader.project_config(pid) == {:loaded, canonical, [], []}
      assert Loader.project_config_message(Loader.project_config(pid)) == nil
    end

    test "the loader says which directory a process started because of config runs in" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = project_with_everything("directory")
      {:ok, canonical} = Minga.Project.Root.canonical_path(root)

      assert Loader.project_directory(start_loader(config_home, root)) == canonical

      # No project, or a project whose config is refused, gives none: such a process runs where Minga runs.
      assert Loader.project_directory(start_loader(config_home, nil)) == nil
      File.chmod!(root, 0o777)
      assert Loader.project_directory(start_loader(config_home, root)) == nil
      assert Loader.project_directory(:no_such_loader) == nil
    end

    test "with no project nothing project-local loads, whatever the VM's directory holds" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      launch_directory = project_with_everything("no_project")
      previous = File.cwd!()
      File.cd!(launch_directory)

      on_exit(fn ->
        File.cd!(previous)
        cleanup.()
      end)

      pid = start_loader(config_home, nil)

      assert nothing_project_local_loaded?()
      assert Loader.project_config(pid) == :none
    end

    test "a root that is too broad loads nothing, directly or through a link" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      link = Path.join(System.tmp_dir!(), "minga_root_link_#{System.unique_integer([:positive])}")
      File.ln_s!("/", link)

      on_exit(fn ->
        cleanup.()
        File.rm(link)
      end)

      for root <- ["/", link] do
        pid = start_loader(config_home, root)

        assert nothing_project_local_loaded?()
        assert Loader.project_config(pid) == {:refused, root, {:too_broad, "/"}}

        # The message names the folder that was opened, and judges the folder it really is.
        assert Loader.project_config_message(Loader.project_config(pid)) ==
                 "Project config in #{root} not loaded: / is too broad and not under version control. " <>
                   "Config loads from a project folder inside it, or once / is a Git repository."
      end
    end

    test "a root that cannot be found loads nothing and says so" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)

      missing =
        Path.join(System.tmp_dir!(), "minga_missing_#{System.unique_integer([:positive])}")

      pid = start_loader(config_home, missing)

      assert nothing_project_local_loaded?()
      assert Loader.project_config(pid) == {:refused, missing, :unresolvable}

      assert Loader.project_config_message(Loader.project_config(pid)) ==
               "Project config in #{Minga.Project.collapse_home(missing)} not loaded: the folder cannot be found."
    end

    test "a reload reads the project the editor passes, and no project unloads it" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = project_with_everything("reload")

      # A project that Minga did not start with loads on reload only if it brings no extensions or plugins.
      File.rm_rf!(Path.join([root, ".minga", "plugins"]))
      pid = start_loader(config_home, nil)
      assert nothing_project_local_loaded?()

      assert :ok = Loader.reload(pid, root)
      assert Options.get(test_options_server(), :tab_width) == 8
      assert {:loaded, _canonical, [_one, _two], []} = Loader.project_config(pid)

      assert :ok = Loader.reload(pid, nil)
      assert nothing_project_local_loaded?()
      assert Loader.project_config(pid) == :none
    end

    test "a relative extension path in a project's config means next to that file" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = Path.join(System.tmp_dir!(), "minga_relative_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "ext"))
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, ".minga.exs"), """
      use Minga.Config
      extension :relative_marker, path: "ext"
      """)

      {:ok, canonical} = Minga.Project.Root.canonical_path(root)
      pid = start_loader(config_home, root)

      assert Loader.project_config_error(pid) == nil
      assert {:ok, entry} = ExtRegistry.get(:relative_marker)
      assert Minga.Extension.Entry.source_path(entry) == Path.join(canonical, "ext")
    end

    test "a folder and a file that a project's config names mean next to that file, and are held to the rule" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      base = Path.join(System.tmp_dir!(), "minga_named_#{System.unique_integer([:positive])}")
      root = Path.join(base, "project")
      on_exit(fn -> File.rm_rf!(base) end)

      for folder <- [
            "project/grammar",
            "project/open_grammar/later",
            "outside/grammar",
            "open/grammar"
          ] do
        File.mkdir_p!(Path.join(base, folder))
      end

      File.write!(Path.join(root, "grammar/highlights.scm"), "(own)")
      File.write!(Path.join(root, "grammar/open.scm"), "(open)")
      File.chmod!(Path.join(root, "grammar/open.scm"), 0o666)
      File.chmod!(Path.join(root, "open_grammar/later"), 0o777)
      File.chmod!(Path.join(base, "open"), 0o777)
      {:ok, canonical} = Minga.Project.Root.canonical_path(root)
      {:ok, canonical_base} = Minga.Project.Root.canonical_path(base)
      report = Path.join(canonical_base, "report")

      # The file records what each name it writes resolves to while it is evaluated.
      File.write!(Path.join(root, ".minga.exs"), """
      use Minga.Config

      File.write!(
        #{inspect(report)},
        :erlang.term_to_binary(%{
          own: Minga.Config.config_code_folder("grammar"),
          open: Minga.Config.config_code_folder("open_grammar"),
          outside: Minga.Config.config_code_folder("../outside/grammar"),
          under_open: Minga.Config.config_code_folder("../open/grammar"),
          file: Minga.Config.read_config_named_file("grammar/highlights.scm"),
          open_file: Minga.Config.read_config_named_file("grammar/open.scm")
        })
      )
      """)

      # `grammar/open.scm` sits in the grammar folder, so that folder is judged without it here.
      pid = start_loader(config_home, root)
      assert Loader.project_config_error(pid) == nil
      found = :erlang.binary_to_term(File.read!(report))

      assert found.file == {:ok, "(own)"}

      assert found.open_file ==
               {:error, {:writable_by_others, Path.join(canonical, "grammar/open.scm")}}

      # A folder with a file anyone can write in it is refused whole, and so is one with an open subfolder.
      assert {:error, own_refusal} = found.own
      assert own_refusal =~ "grammar/open.scm"
      assert {:error, open_refusal} = found.open
      assert open_refusal =~ "anyone on this machine can write"
      # `..` gains nothing: the folder is judged where it really is, with the folders above it.
      assert found.outside == {:ok, Path.join(canonical_base, "outside/grammar")}
      assert {:error, under_open_refusal} = found.under_open
      assert under_open_refusal =~ Path.join(canonical_base, "open")

      # Outside a config file there is no such folder and no rule: the user's own code names what it likes.
      assert Minga.Config.expand_config_path("grammar") == Path.expand("grammar")
      assert Minga.Config.config_code_folder("grammar") == {:ok, Path.expand("grammar")}
    end

    test "a folder anyone on the machine can write gives no config, directly or through a link" do
      # The finding this guards: another account plants a marker and `.minga.exs` in a shared folder such as /tmp.
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      shared = project_with_everything("shared")
      File.chmod!(shared, 0o777)
      {:ok, canonical} = Minga.Project.Root.canonical_path(shared)

      link =
        Path.join(System.tmp_dir!(), "minga_shared_link_#{System.unique_integer([:positive])}")

      File.ln_s!(shared, link)

      on_exit(fn ->
        cleanup.()
        File.rm(link)
      end)

      for root <- [shared, link] do
        pid = start_loader(config_home, root)

        assert nothing_project_local_loaded?()
        assert Loader.project_config(pid) == {:refused, root, {:writable_by_others, canonical}}

        assert Loader.project_config_message(Loader.project_config(pid)) =~
                 "not loaded: anyone on this machine can write"

        assert Loader.project_config_message(Loader.project_config(pid)) =~ "chmod o-w"
      end
    end

    test "a config file anyone can write is left out, and the rest of the project's config loads" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = project_with_everything("open_file")
      {:ok, canonical} = Minga.Project.Root.canonical_path(root)
      File.chmod!(Path.join(root, ".minga.exs"), 0o666)

      pid = start_loader(config_home, root)

      refute Options.get(test_options_server(), :tab_width) == 8
      assert [_marker] = Options.get(test_options_server(), :agent_mcp_servers)

      assert {:loaded, ^canonical, loaded, [{left_out, {:writable_by_others, _file}}]} =
               Loader.project_config(pid)

      assert Path.relative_to(left_out, canonical) == ".minga.exs"

      assert Enum.map(loaded, &Path.relative_to(&1, canonical)) == [
               ".minga/mcp.json",
               ".minga/plugins"
             ]

      message = Loader.project_config_message(Loader.project_config(pid))
      assert message =~ "Project config loaded from"
      assert message =~ ".minga.exs (anyone on this machine can write .minga.exs."
    end

    test "a plugin anyone can write is not registered" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = project_with_everything("open_plugin")
      File.chmod!(Path.join([root, ".minga", "plugins", "marker_plugin"]), 0o777)

      pid = start_loader(config_home, root)

      assert ExtRegistry.get(:marker_plugin) == :error

      assert Loader.load_error(pid) =~
               "Plugin marker_plugin not loaded: anyone on this machine can write"
    end

    test "a plugin with an empty subfolder anyone can write is not registered: a file added later would be loaded" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = project_with_everything("open_subfolder")
      later = Path.join([root, ".minga", "plugins", "marker_plugin", "lib", "later"])
      File.mkdir_p!(later)
      File.chmod!(later, 0o777)

      pid = start_loader(config_home, root)

      assert ExtRegistry.get(:marker_plugin) == :error

      assert Loader.load_error(pid) =~
               "Plugin marker_plugin not loaded: anyone on this machine can write"

      assert Loader.load_error(pid) =~
               "marker_plugin/lib/later. Remove write access for others (chmod o-w,"
    end

    test "a plugin whose plugin.json or script anyone can write is not registered" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)

      for {label, open} <- [{"open_manifest", "plugin.json"}, {"open_script", "bin/serve.sh"}] do
        root = project_with_everything(label)
        plugin = Path.join([root, ".minga", "plugins", "marker_plugin"])
        File.mkdir_p!(Path.join(plugin, "bin"))

        File.write!(
          Path.join(plugin, "plugin.json"),
          ~s({"name":"marker","mcp_servers":[{"name":"m","command":"${MINGA_PLUGIN_ROOT}/bin/serve.sh"}]})
        )

        File.write!(Path.join(plugin, "bin/serve.sh"), "#!/bin/sh\n")
        File.chmod!(Path.join(plugin, open), 0o777)

        pid = start_loader(config_home, root)

        assert ExtRegistry.get(:marker_plugin) == :error
        assert Loader.load_error(pid) =~ "marker_plugin/#{open}. Remove write access for others"
      end
    end

    test "nothing is read from a .minga folder anyone can write: its plugins and its MCP servers stay out" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = project_with_everything("open_dot_minga")
      {:ok, canonical} = Minga.Project.Root.canonical_path(root)
      File.chmod!(Path.join(root, ".minga"), 0o777)

      pid = start_loader(config_home, root)

      # Another account could rename the plugins folder away and put its own in its place.
      assert ExtRegistry.get(:marker_plugin) == :error
      assert Options.get(test_options_server(), :agent_mcp_servers) == []
      # `.minga.exs` sits in the project folder itself, which is the user's own.
      assert Options.get(test_options_server(), :tab_width) == 8

      open = {:writable_by_others, Path.join(canonical, ".minga")}

      assert {:loaded, ^canonical, [_config_file], [{_mcp_json, ^open}, {_plugins_folder, ^open}]} =
               Loader.project_config(pid)
    end

    test "a plugin is registered under its canonical path, so a link repointed later changes nothing" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = project_with_everything("linked_plugin")
      plugins = Path.join([root, ".minga", "plugins"])
      File.rm_rf!(Path.join(plugins, "marker_plugin"))
      File.mkdir_p!(Path.join(root, "checked"))
      File.mkdir_p!(Path.join(root, "swapped_in"))
      File.ln_s!(Path.join(root, "checked"), Path.join(plugins, "marker_plugin"))
      {:ok, checked} = Minga.Project.Root.canonical_path(Path.join(root, "checked"))

      start_loader(config_home, root)

      assert {:ok, entry} = ExtRegistry.get(:marker_plugin)
      assert Minga.Extension.Entry.source_path(entry) == checked

      # The name in the plugins folder now leads elsewhere. What was registered is the folder that was checked.
      File.rm!(Path.join(plugins, "marker_plugin"))
      File.ln_s!(Path.join(root, "swapped_in"), Path.join(plugins, "marker_plugin"))

      assert {:ok, entry} = ExtRegistry.get(:marker_plugin)
      assert Minga.Extension.Entry.source_path(entry) == checked
    end

    test "an extension path in a project's config must lead to code that is the user's own" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = Path.join(System.tmp_dir!(), "minga_ext_owner_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)

      for name <- ["own_ext", "open_ext", "open_parent/under_open_ext"] do
        File.mkdir_p!(Path.join([root, name, "lib"]))
        File.write!(Path.join([root, name, "lib", "ext.ex"]), "")
      end

      # An empty folder anyone can write, and a folder that sits under one.
      File.mkdir_p!(Path.join([root, "open_ext", "lib", "later"]))
      File.chmod!(Path.join([root, "open_ext", "lib", "later"]), 0o777)
      File.chmod!(Path.join(root, "open_parent"), 0o777)
      File.ln_s!(Path.join(root, "own_ext"), Path.join(root, "linked_ext"))

      File.write!(Path.join(root, ".minga.exs"), """
      use Minga.Config
      extension :own_marker, path: "own_ext"
      extension :linked_marker, path: "linked_ext"
      extension :open_marker, path: "open_ext"
      extension :under_open_marker, path: "open_parent/under_open_ext"
      set :tab_width, 8
      """)

      {:ok, canonical} = Minga.Project.Root.canonical_path(root)
      pid = start_loader(config_home, root)

      assert {:ok, _entry} = ExtRegistry.get(:own_marker)
      assert ExtRegistry.get(:open_marker) == :error
      assert ExtRegistry.get(:under_open_marker) == :error
      # What is registered is the canonical folder that was checked, not the name the config used.
      assert {:ok, linked} = ExtRegistry.get(:linked_marker)
      assert Minga.Extension.Entry.source_path(linked) == Path.join(canonical, "own_ext")
      # The rest of the file still applies, and the file itself counts as loaded.
      assert Options.get(test_options_server(), :tab_width) == 8
      assert Loader.project_config_error(pid) == nil
    end

    # A project with scripts: one the user's own, one anyone can write.
    defp project_with_scripts(label) do
      root = project_with_everything(label)
      File.mkdir_p!(Path.join(root, "scripts"))

      for name <- ["own.sh", "open.sh"] do
        File.write!(Path.join([root, "scripts", name]), "#!/bin/sh\n")
        File.chmod!(Path.join([root, "scripts", name]), 0o755)
      end

      File.chmod!(Path.join(root, "scripts/open.sh"), 0o777)
      {:ok, canonical} = Minga.Project.Root.canonical_path(root)
      {root, canonical}
    end

    defp servers_by_name do
      Map.new(Options.get(test_options_server(), :agent_mcp_servers), &{&1.name, &1})
    end

    test "an MCP server from .minga/mcp.json starts from an examined program, in the project root" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      {root, canonical} = project_with_scripts("mcp_program")

      File.write!(
        Path.join([root, ".minga", "mcp.json"]),
        JSON.encode!(%{
          "mcpServers" => %{
            "own" => %{
              "command" => "scripts/own.sh",
              "args" => ["scripts/open.sh", "--config=scripts/x"],
              "cwd" => "/tmp"
            },
            "open" => %{"command" => "scripts/open.sh"},
            "missing" => %{"command" => "scripts/later.sh"},
            "on_path" => %{"command" => "true", "cwd" => "/tmp"}
          }
        })
      )

      pid = start_loader(config_home, root)
      servers = servers_by_name()

      assert Enum.sort(Map.keys(servers)) == ["on_path", "own"]

      # The canonical program that was examined is what is registered, and the project's own data does not
      # choose the directory. Arguments are the project's own and are passed on untouched.
      assert servers["own"].command == Path.join(canonical, "scripts/own.sh")
      assert servers["own"].cwd == canonical
      assert servers["own"].args == ["scripts/open.sh", "--config=scripts/x"]
      # A bare name is the user's environment: it is found on PATH when the server starts.
      assert servers["on_path"].command == "true"
      assert servers["on_path"].cwd == canonical

      assert Loader.load_error(pid) =~
               "MCP server open not loaded: anyone on this machine can write"

      assert Loader.load_error(pid) =~ "MCP server missing not loaded:"

      assert Loader.load_error(pid) =~
               "scripts/later.sh is not there. Create it, or correct the name, and reload config."
    end

    test "servers and hooks that a project's .minga.exs adds are the project's: examined, and run in its root" do
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :agent_mcp_servers, [%{name: "mine", command: "true"}]
        set :agent_hooks, [%{event: :stop, command: "echo mine"}]
        """)

      on_exit(cleanup)
      {root, canonical} = project_with_scripts("exs_processes")
      File.rm!(Path.join([root, ".minga", "mcp.json"]))

      File.write!(Path.join(root, ".minga.exs"), """
      use Minga.Config

      set :agent_mcp_servers, [
        %{name: "mine", command: "true"},
        %{name: "own", command: "scripts/own.sh", cwd: "/tmp"},
        %{name: "open", command: "scripts/open.sh"}
      ]

      set :agent_hooks, [
        %{event: :stop, command: "echo mine"},
        %{event: :stop, command: "scripts/own.sh", cwd: "/tmp"}
      ]
      """)

      pid = start_loader(config_home, root)
      servers = servers_by_name()

      assert Enum.sort(Map.keys(servers)) == ["mine", "own"]
      # The entry the user's own config declared is left exactly as it was.
      assert servers["mine"] == %{name: "mine", command: "true"}
      assert servers["own"].command == Path.join(canonical, "scripts/own.sh")
      assert servers["own"].cwd == canonical

      assert [%{command: "echo mine"} = mine, %{command: "scripts/own.sh", cwd: ^canonical}] =
               Options.get(test_options_server(), :agent_hooks)

      refute Map.has_key?(mine, :cwd)

      assert Loader.project_config_error(pid) =~
               "MCP server open not loaded: anyone on this machine can write"
    end

    test "a project folder its group can write loads where an account has its own group, and not on macOS" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = project_with_everything("group")
      {:ok, canonical} = Minga.Project.Root.canonical_path(root)
      File.chmod!(root, 0o775)

      pid = start_loader(config_home, root)

      # The rule is decided in `Minga.Project.Trust`, whose own tests cover both platforms with an injected one.
      case Minga.Project.Trust.platform() do
        :macos ->
          assert nothing_project_local_loaded?()
          assert Loader.project_config(pid) == {:refused, root, {:writable_by_group, canonical}}
          assert Loader.project_config_message(Loader.project_config(pid)) =~ "chmod g-w"

        :other ->
          assert Options.get(test_options_server(), :tab_width) == 8
          assert {:loaded, _canonical, [_one, _two, _three], []} = Loader.project_config(pid)
      end
    end

    test "a project inside another never reads the outer project's files" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      outer = project_with_everything("outer")
      inner = Path.join(outer, "packages/inner")
      File.mkdir_p!(inner)
      {:ok, canonical} = Minga.Project.Root.canonical_path(inner)

      pid = start_loader(config_home, inner)

      assert nothing_project_local_loaded?()
      assert Loader.project_config(pid) == {:loaded, canonical, [], []}
    end

    test "after a switch to another project a reload works, and only a project that declares extensions is left out" do
      {dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)

      project = fn label, content ->
        root =
          Path.join(System.tmp_dir!(), "minga_#{label}_#{System.unique_integer([:positive])}")

        File.mkdir_p!(Path.join(root, "ext"))
        if content, do: File.write!(Path.join(root, ".minga.exs"), content)
        on_exit(fn -> File.rm_rf!(root) end)
        root
      end

      started_in =
        project.(
          "a",
          "use Minga.Config\nset :tab_width, 8\nextension :declared_in_a, path: \"ext\"\n"
        )

      plain = project.("b", nil)

      declares =
        project.(
          "c",
          "use Minga.Config\nset :tab_width, 6\nextension :declared_in_c, path: \"ext\"\n"
        )

      pid = start_loader(config_home, started_in)
      assert Options.get(test_options_server(), :tab_width) == 8

      # The sequence that failed: switch to a project without config, change the global config, reload.
      File.write!(Path.join(dir, "config.exs"), "use Minga.Config\nset :scroll_margin, 9\n")
      assert :ok = Loader.reload(pid, plain)
      assert Options.get(test_options_server(), :scroll_margin) == 9
      refute Options.get(test_options_server(), :tab_width) == 8
      assert {:loaded, _plain, [], []} = Loader.project_config(pid)

      # A project that declares extensions cannot be admitted after start. Only its config is left out.
      assert :ok = Loader.reload(pid, declares)
      assert Options.get(test_options_server(), :scroll_margin) == 9
      refute Options.get(test_options_server(), :tab_width) == 6
      assert Loader.project_config(pid) == {:refused, declares, :extensions_need_restart}

      assert Loader.project_config_message(Loader.project_config(pid)) =~
               "it declares extensions or has plugins, and those load only when Minga starts."

      # A plugin is an extension too. A project that only has a plugins folder is left out the same way,
      # and its plugin is not registered, so nothing of it is compiled.
      with_plugin = project_with_everything("d")
      assert :ok = Loader.reload(pid, with_plugin)
      assert Loader.project_config(pid) == {:refused, with_plugin, :extensions_need_restart}
      assert ExtRegistry.get(:marker_plugin) == :error
      refute Options.get(test_options_server(), :tab_width) == 8
      # None of its MCP servers is registered either, so none can be started.
      assert Options.get(test_options_server(), :agent_mcp_servers) == []

      # Back in the project Minga started with, its config loads again, with or without a restart.
      assert :ok = Loader.reload(pid, started_in)
      assert Options.get(test_options_server(), :tab_width) == 8
      assert {:loaded, _started_in, [_config], []} = Loader.project_config(pid)
      assert :ok = Loader.reload(pid)

      restarted = start_loader(config_home, started_in)
      assert Options.get(test_options_server(), :tab_width) == 8
      assert {:loaded, _started_in, [_config], []} = Loader.project_config(restarted)
    end

    test "the project Minga started with is recognised on reload under another spelling of its path" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = project_with_everything("spelling")
      {:ok, canonical} = Minga.Project.Root.canonical_path(root)
      link = root <> "_link"
      File.ln_s!(root, link)
      on_exit(fn -> File.rm(link) end)

      pid = start_loader(config_home, root)
      assert {:ok, _entry} = ExtRegistry.get(:marker_plugin)

      # It has a plugin, so as another project it would be left out. It is the same project.
      assert :ok = Loader.reload(pid, link)
      assert {:loaded, ^canonical, [_one, _two, _three], []} = Loader.project_config(pid)
      assert Options.get(test_options_server(), :tab_width) == 8
      assert {:ok, _entry} = ExtRegistry.get(:marker_plugin)
    end

    test "the project Minga started with must still declare the extensions it declared then" do
      {_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      on_exit(cleanup)
      root = Path.join(System.tmp_dir!(), "minga_changed_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "ext"))
      on_exit(fn -> File.rm_rf!(root) end)
      File.write!(Path.join(root, ".minga.exs"), "use Minga.Config\n")

      pid = start_loader(config_home, root)

      File.write!(
        Path.join(root, ".minga.exs"),
        "use Minga.Config\nextension :added_later, path: \"ext\"\n"
      )

      assert {:error, "Extension declarations changed; restart Minga before config reload"} =
               Loader.reload(pid)
    end

    test "the loader's source never asks for the VM's working directory" do
      source = File.read!("lib/minga/config/loader.ex")

      refute source =~ "File.cwd"
      refute source =~ ":file.get_cwd"
    end
  end

  describe "gui_settings.exs" do
    test "overrides project config before after.exs" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      project_dir =
        Path.join(System.tmp_dir!(), "minga_gui_cfg_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      File.write!(Path.join(project_dir, ".minga.exs"), """
      use Minga.Config
      set :tab_width, 6
      """)

      File.write!(Path.join(minga_dir, "gui_settings.exs"), """
      use Minga.Config
      set :tab_width, 8
      """)

      on_exit(fn ->
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_gui_settings_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

      assert Loader.gui_settings_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 8
    end

    test "after.exs still overrides gui_settings.exs" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      project_dir =
        Path.join(System.tmp_dir!(), "minga_gui_after_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      File.write!(Path.join(project_dir, ".minga.exs"), """
      use Minga.Config
      set :tab_width, 6
      """)

      File.write!(Path.join(minga_dir, "gui_settings.exs"), """
      use Minga.Config
      set :tab_width, 8
      """)

      File.write!(Path.join(minga_dir, "after.exs"), """
      use Minga.Config
      set :tab_width, 9
      """)

      on_exit(fn ->
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_gui_after_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

      assert Loader.gui_settings_error(pid) == nil
      assert Loader.after_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 9
    end

    test "reload picks up gui_settings.exs changes with the same precedence" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      File.write!(Path.join(minga_dir, "gui_settings.exs"), """
      use Minga.Config
      set :tab_width, 4
      """)

      File.write!(Path.join(minga_dir, "after.exs"), """
      use Minga.Config
      set :line_numbers, :absolute
      """)

      on_exit(cleanup)

      name = :"loader_gui_reload_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)
      assert Options.get(test_options_server(), :tab_width) == 4
      assert Options.get(test_options_server(), :line_numbers) == :absolute

      File.write!(Path.join(minga_dir, "gui_settings.exs"), """
      use Minga.Config
      set :tab_width, 8
      set :line_numbers, :relative
      """)

      assert :ok = Loader.reload(pid)
      assert Options.get(test_options_server(), :tab_width) == 8
      assert Options.get(test_options_server(), :line_numbers) == :absolute
    end

    test "marks gui_settings.exs values as explicit so GUI defaults preserve them" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      File.write!(Path.join(minga_dir, "gui_settings.exs"), """
      use Minga.Config
      set :line_numbers, :hybrid
      """)

      on_exit(cleanup)

      name = :"loader_gui_explicit_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      assert Loader.gui_settings_error(pid) == nil
      assert Options.get(test_options_server(), :line_numbers) == :hybrid
      assert Options.explicitly_set?(test_options_server(), :line_numbers)

      gui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :native_gui}
      assert :ok = MingaEditor.Startup.apply_gui_defaults(gui_caps, test_options_server())
      assert Options.get(test_options_server(), :line_numbers) == :hybrid
    end

    test "gui_settings.exs default-valued selections override config.exs values" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :line_spacing, 1.2
        set :wrap, true
        """)

      File.write!(Path.join(minga_dir, "gui_settings.exs"), """
      use Minga.Config
      set :line_spacing, 1.0
      set :wrap, false
      """)

      on_exit(cleanup)

      name = :"loader_gui_default_values_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      assert Loader.gui_settings_error(pid) == nil
      assert Options.get(test_options_server(), :line_spacing) == 1.0
      assert Options.get(test_options_server(), :wrap) == false
      assert Options.explicitly_set?(test_options_server(), :line_spacing)
      assert Options.explicitly_set?(test_options_server(), :wrap)

      gui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :native_gui}
      assert :ok = MingaEditor.Startup.apply_gui_defaults(gui_caps, test_options_server())
      assert Options.get(test_options_server(), :line_spacing) == 1.0
    end

    test "non-GUI config sources do not mark options explicit" do
      {_minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      project_dir =
        Path.join(
          System.tmp_dir!(),
          "minga_non_gui_explicit_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)

      File.write!(Path.join(project_dir, ".minga.exs"), """
      use Minga.Config
      set :line_numbers, :relative
      """)

      on_exit(fn ->
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_non_gui_explicit_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

      assert Loader.gui_settings_error(pid) == nil
      refute Options.explicitly_set?(test_options_server(), :line_numbers)
    end
  end

  describe "after.exs" do
    test "after.exs runs after config and can use user modules" do
      {minga_dir, config_home, cleanup} = make_config_dir("")
      modules_dir = Path.join(minga_dir, "modules")
      File.mkdir_p!(modules_dir)

      File.write!(Path.join(modules_dir, "helper.ex"), """
      defmodule Minga.UserModules.Helper do
        def default_tab_width, do: 6
      end
      """)

      File.write!(Path.join(minga_dir, "after.exs"), """
      use Minga.Config
      set :tab_width, Minga.UserModules.Helper.default_tab_width()
      """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.UserModules.Helper)
        :code.delete(Minga.UserModules.Helper)
      end)

      name = :"loader_after_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      assert Loader.after_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 6
    end
  end

  describe "reload/1" do
    test "loads modeline_segment declarations from config" do
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config

        modeline_segment :loader_words, side: :left, priority: 42 do
          {" WORDS ", ctx.info_fg, ctx.bar_bg, [], nil}
        end
        """)

      on_exit(cleanup)

      name = :"loader_modeline_segment_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name, config_home: config_home)

      assert %{side: :left, priority: 42, source: :config} =
               ModelineSegments.lookup(:loader_words)
    end

    test "reload replaces stale config modeline segments" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config

        modeline_segment :loader_stale_segment, side: :right do
          {" OLD ", ctx.info_fg, ctx.bar_bg, [], nil}
        end
        """)

      on_exit(cleanup)

      name = :"loader_reload_modeline_segment_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)
      assert ModelineSegments.lookup(:loader_stale_segment) != nil

      File.write!(Path.join(minga_dir, "config.exs"), """
      use Minga.Config

      modeline_segment :loader_fresh_segment, side: :left do
        {" NEW ", ctx.info_fg, ctx.bar_bg, [], nil}
      end
      """)

      assert :ok = Loader.reload(pid)
      assert ModelineSegments.lookup(:loader_stale_segment) == nil
      assert %{side: :left, source: :config} = ModelineSegments.lookup(:loader_fresh_segment)
    end

    test "reload clears stale config-owned keybinds, themes, languages, recipes, and scopes",
         ctx do
      ContributionCleanup.unregister_source(:config,
        keymap: ctx.keymap_server,
        callbacks: %{themes: &Theme.unregister_source/1}
      )

      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config

        bind :insert, "C-j", :loader_reload_keybind, "Loader reload keybind"

        doom = MingaEditor.UI.Theme.get!(:doom_one)

        MingaEditor.UI.Theme.register_themes(%{
          loader_reload_theme: %{doom | name: :loader_reload_theme, editor: %{doom.editor | fg: 0x111111}}
        }, :config)

        Minga.Language.Registry.register(%Minga.Language{
          name: :loader_reload_language,
          label: "Loader Reload Language",
          comment_token: "// ",
          extensions: ["loader_reload_language"]
        })

        Minga.Tool.Recipe.Registry.register(%Minga.Tool.Recipe{
          name: :loader_reload_recipe,
          label: "Loader Reload Recipe",
          description: "Loader reload recipe",
          provides: ["loader-reload-recipe"],
          method: :npm,
          package: "loader-reload-recipe",
          homepage: "https://example.invalid/loader-reload-recipe",
          category: :formatter,
          languages: [:elixir]
        })

        Minga.Keymap.Scope.register(:config, :loader_reload_scope, Minga.Keymap.Scope.Editor)
        """)

      on_exit(cleanup)

      on_exit(fn ->
        ContributionCleanup.unregister_source(:config,
          keymap: ctx.keymap_server,
          callbacks: %{themes: &Theme.unregister_source/1}
        )

        Theme.unregister_source(:config)
      end)

      name = :"loader_reload_registry_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      {:ok, keys} = Minga.Keymap.KeyParser.parse("C-j")

      assert {:command, :loader_reload_keybind, _desc} =
               KeymapActive.mode_trie(ctx.keymap_server, :insert)
               |> Minga.Keymap.Bindings.lookup_sequence(keys)

      assert {:ok, %Theme{name: :loader_reload_theme, editor: %{fg: 0x111111}}} =
               Theme.get(:loader_reload_theme)

      assert %Language{name: :loader_reload_language} =
               LanguageRegistry.get(:loader_reload_language)

      assert %Recipe{name: :loader_reload_recipe} = RecipeRegistry.get(:loader_reload_recipe)
      assert Minga.Keymap.Scope.module_for(:loader_reload_scope) == Minga.Keymap.Scope.Editor

      File.write!(Path.join(minga_dir, "config.exs"), """
      use Minga.Config

      bind :insert, "C-k", :loader_reload_keybind, "Loader reload keybind"

      doom = MingaEditor.UI.Theme.get!(:doom_one)

      MingaEditor.UI.Theme.register_themes(%{
        loader_reload_theme: %{doom | name: :loader_reload_theme, editor: %{doom.editor | fg: 0x222222}}
      }, :config)

      Minga.Language.Registry.register(%Minga.Language{
        name: :loader_reload_language_fresh,
        label: "Loader Reload Fresh Language",
        comment_token: "// ",
        extensions: ["loader_reload_language_fresh"]
      })

      Minga.Tool.Recipe.Registry.register(%Minga.Tool.Recipe{
        name: :loader_reload_recipe_fresh,
        label: "Loader Reload Fresh Recipe",
        description: "Loader reload fresh recipe",
        provides: ["loader-reload-recipe-fresh"],
        method: :npm,
        package: "loader-reload-recipe-fresh",
        homepage: "https://example.invalid/loader-reload-recipe-fresh",
        category: :formatter,
        languages: [:elixir]
      })

      Minga.Keymap.Scope.register(:config, :loader_reload_scope_fresh, Minga.Keymap.Scope.Editor)
      """)

      assert :ok = Loader.reload(pid)

      {:ok, keys} = Minga.Keymap.KeyParser.parse("C-j")

      assert :not_found =
               KeymapActive.mode_trie(ctx.keymap_server, :insert)
               |> Minga.Keymap.Bindings.lookup_sequence(keys)

      {:ok, keys} = Minga.Keymap.KeyParser.parse("C-k")

      assert {:command, :loader_reload_keybind, _desc} =
               KeymapActive.mode_trie(ctx.keymap_server, :insert)
               |> Minga.Keymap.Bindings.lookup_sequence(keys)

      assert {:ok, %Theme{name: :loader_reload_theme, editor: %{fg: 0x222222}}} =
               Theme.get(:loader_reload_theme)

      assert LanguageRegistry.get(:loader_reload_language) == nil

      assert %Language{name: :loader_reload_language_fresh} =
               LanguageRegistry.get(:loader_reload_language_fresh)

      assert RecipeRegistry.get(:loader_reload_recipe) == nil

      assert %Recipe{name: :loader_reload_recipe_fresh} =
               RecipeRegistry.get(:loader_reload_recipe_fresh)

      assert Minga.Keymap.Scope.module_for(:loader_reload_scope) == nil

      assert Minga.Keymap.Scope.module_for(:loader_reload_scope_fresh) ==
               Minga.Keymap.Scope.Editor
    end

    test "reload surfaces config cleanup failures in the loader error state" do
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      on_exit(cleanup)

      fail_cleanup = :atomics.new(1, [])

      cleanup_callbacks = %{
        loader_reload_cleanup_failure: fn
          :config ->
            case :atomics.get(fail_cleanup, 1) do
              0 -> :ok
              1 -> raise "cleanup failure"
            end

          _source ->
            :ok
        end
      }

      name = :"loader_reload_cleanup_failure_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(
          name: name,
          config_home: config_home,
          cleanup_callbacks: cleanup_callbacks
        )

      assert Loader.load_error(pid) == nil

      :ok = :atomics.put(fail_cleanup, 1, 1)

      assert {:error, msg} = Loader.reload(pid)
      assert msg =~ "Config reload cleanup for :config failed"
      assert msg =~ "cleanup failure"
      assert Loader.load_error(pid) =~ "Config reload cleanup for :config failed"

      :ok = :atomics.put(fail_cleanup, 1, 0)
      assert :ok = Loader.reload(pid)
      assert Loader.load_error(pid) == nil
    end

    @tag :heavy
    test "reload surfaces start_all failures with cleanup details" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      on_exit(cleanup)

      previous_load_extensions = Application.get_env(:minga, :load_extensions)
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :load_extensions, false)

      on_exit(fn ->
        restore_application_env(:load_extensions, previous_load_extensions)
      end)

      ensure_extension_runtime()
      suffix = System.unique_integer([:positive])
      extension_name = :"loader_start_all_failure_#{suffix}"
      ext_module = Module.concat(["LoaderStartAllFailure#{suffix}"])

      ext_dir =
        Path.join(
          System.tmp_dir!(),
          "minga_loader_start_all_#{suffix}"
        )

      File.mkdir_p!(ext_dir)
      ext_path = Path.join(ext_dir, "start_all_failure.ex")

      File.write!(
        ext_path,
        """
        defmodule #{inspect(ext_module)} do
          use Minga.Extension

          @impl true
          def name, do: #{inspect(extension_name)}

          @impl true
          def description, do: "Loader start_all failure test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:error, :intentional_failure}
        end
        """
      )

      on_exit(fn ->
        if Process.whereis(RootSupervisor) do
          RootSupervisor.terminate_root(RootSupervisor, extension_name)
        end

        if Process.whereis(ExtRegistry), do: ExtRegistry.unregister(extension_name)
        File.rm_rf!(ext_dir)
        :code.purge(ext_module)
        :code.delete(ext_module)
      end)

      cleanup_callbacks = %{
        loader_reload_start_all_cleanup: fn
          {:extension, ^extension_name} ->
            raise "cleanup failure"

          _source ->
            :ok
        end
      }

      File.write!(
        Path.join(minga_dir, "config.exs"),
        """
        use Minga.Config
        extension #{inspect(extension_name)}, path: #{inspect(ext_dir)}
        """
      )

      name = :"loader_reload_start_all_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(
          name: name,
          cleanup_callbacks: cleanup_callbacks,
          config_home: config_home
        )

      assert Loader.load_error(pid) == nil
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :load_extensions, true)

      on_exit(fn ->
        ExtSupervisor.stop_all()
        ExtRegistry.reset()
      end)

      assert {:error, msg} = Loader.reload(pid)
      assert msg =~ "Extension start_all failed"
      assert msg =~ Atom.to_string(extension_name)
      assert msg =~ "cleanup_failed"
      assert msg =~ "intentional_failure"
      assert msg =~ "cleanup failure"
      assert Loader.load_error(pid) =~ "Extension start_all failed"
    end

    test "reload detects one-argument module declaration changes" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        extension Minga.Extensions.MCP
        """)

      on_exit(fn ->
        ExtRegistry.reset()
        cleanup.()
      end)

      name = :"loader_module_declaration_reload_#{System.unique_integer([:positive])}"
      {:ok, loader} = Loader.start_link(name: name, config_home: config_home)
      assert Loader.load_error(loader) == nil
      assert {:ok, %{module: Minga.Extensions.MCP}} = ExtRegistry.get(:minga_mcp)

      File.write!(Path.join(minga_dir, "config.exs"), "use Minga.Config\n")

      assert {:error, message} = Loader.reload(loader)
      assert message == "Extension declarations changed; restart Minga before config reload"
      assert Loader.load_error(loader) == message
      # A rejected reload keeps the last loaded config, which evaluated.
      assert Loader.config_eval_error(loader) == nil
      assert {:ok, %{module: Minga.Extensions.MCP}} = ExtRegistry.get(:minga_mcp)
    end

    test "reload detects byte changes after a dynamic declaration in quoted syntax" do
      source = """
      use Minga.Config

      _ =
        quote do
          OtherConfig.extension(name, options)
        end

      set :tab_width, 4
      """

      {minga_dir, config_home, cleanup} = make_config_dir(source <> "# original suffix\n")
      on_exit(cleanup)

      name = :"loader_dynamic_declaration_#{System.unique_integer([:positive])}"
      loader = start_supervised!({Loader, name: name, config_home: config_home})
      assert Loader.load_error(loader) == nil

      File.write!(Path.join(minga_dir, "config.exs"), source <> "# changed suffix\n")

      assert {:error, message} = Loader.reload(loader)
      assert message == "Extension declarations changed; restart Minga before config reload"
    end

    test "reload detects a newly created project extension declaration" do
      {_minga_dir, config_home, cleanup_config} = make_config_dir("use Minga.Config\n")

      project_dir =
        Path.join(
          System.tmp_dir!(),
          "minga-loader-new-project-config-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)
      extension_name = :loader_new_project_extension

      on_exit(fn ->
        File.rm_rf!(project_dir)
        ExtRegistry.unregister(extension_name)
        cleanup_config.()
      end)

      name = :"loader_new_project_config_#{System.unique_integer([:positive])}"

      {:ok, loader} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

      assert Loader.load_error(loader) == nil

      File.write!(Path.join(project_dir, ".minga.exs"), """
      use Minga.Config
      extension #{inspect(extension_name)}, path: "/tmp/new-project-extension"
      """)

      assert {:error, message} = Loader.reload(loader)
      assert message == "Extension declarations changed; restart Minga before config reload"
      assert :error = ExtRegistry.get(extension_name)
    end

    @tag :heavy
    test "reload rejects changed extension declarations before stopping the admitted runtime" do
      ensure_extension_runtime()
      suffix = System.unique_integer([:positive])
      extension_name = String.to_atom("loader_declaration_pinned_#{suffix}")
      extension_module = Module.concat(["LoaderDeclarationPinned#{suffix}"])
      original_dir = Path.join(System.tmp_dir!(), "minga-loader-declaration-original-#{suffix}")

      replacement_dir =
        Path.join(System.tmp_dir!(), "minga-loader-declaration-replacement-#{suffix}")

      File.mkdir_p!(original_dir)
      File.mkdir_p!(replacement_dir)

      source = """
      defmodule #{inspect(extension_module)} do
        use Minga.Extension
        @impl true
        def name, do: #{inspect(extension_name)}
        @impl true
        def description, do: "Config declaration generation fixture"
        @impl true
        def version, do: "1.0.0"
        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """

      File.write!(Path.join(original_dir, "extension.ex"), source)
      File.write!(Path.join(replacement_dir, "extension.ex"), source)

      {minga_dir, config_home, cleanup_config} =
        make_config_dir("""
        use Minga.Config
        extension #{inspect(extension_name)}, path: #{inspect(original_dir)}
        """)

      on_exit(fn ->
        ExtSupervisor.stop_all()
        ExtRegistry.reset()
        cleanup_config.()
        File.rm_rf!(original_dir)
        File.rm_rf!(replacement_dir)
        :code.purge(extension_module)
        :code.delete(extension_module)
      end)

      loader_name = String.to_atom("loader_declaration_reload_#{suffix}")
      {:ok, loader} = Loader.start_link(name: loader_name, config_home: config_home)
      assert Loader.load_error(loader) == nil
      assert {:ok, declared} = ExtRegistry.get(extension_name)

      assert {:ok, runtime_pid} =
               ExtSupervisor.start_extension(
                 Minga.Extension.Supervisor,
                 ExtRegistry,
                 extension_name,
                 declared
               )

      File.write!(Path.join(minga_dir, "config.exs"), """
      use Minga.Config
      extension #{inspect(extension_name)}, path: #{inspect(replacement_dir)}
      """)

      assert {:error, message} = Loader.reload(loader)
      assert message == "Extension declarations changed; restart Minga before config reload"

      assert {:ok, unchanged} = ExtRegistry.get(extension_name)
      assert Minga.Extension.Entry.source_path(unchanged) == Path.expand(original_dir)
      assert unchanged.pid == runtime_pid

      runtime_supervisor = InstanceRegistry.via(InstanceRegistry, :runtime, extension_name)
      assert RuntimeSupervisor.local_child(runtime_supervisor) == {:ok, runtime_pid}
    end

    @tag :heavy
    test "reload reports changed path artifacts without replacing the admitted runtime" do
      ensure_extension_runtime()
      suffix = System.unique_integer([:positive])
      extension_name = String.to_atom("loader_generation_pinned_#{suffix}")
      extension_module = Module.concat(["LoaderGenerationPinned#{suffix}"])
      extension_dir = Path.join(System.tmp_dir!(), "minga-loader-generation-#{suffix}")
      source_path = Path.join(extension_dir, "extension.ex")
      compile_log = Path.join(extension_dir, "compiled.log")
      File.mkdir_p!(extension_dir)

      source = fn version ->
        """
        File.write!(#{inspect(compile_log)}, #{inspect(version <> "\n")}, [:append])

        defmodule #{inspect(extension_module)} do
          use Minga.Extension
          @impl true
          def name, do: #{inspect(extension_name)}
          @impl true
          def description, do: "Config reload generation fixture"
          @impl true
          def version, do: #{inspect(version)}
          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """
      end

      File.write!(source_path, source.("1.0.0"))

      {_minga_dir, config_home, cleanup_config} =
        make_config_dir("""
        use Minga.Config
        extension #{inspect(extension_name)}, path: #{inspect(extension_dir)}
        """)

      on_exit(fn ->
        ExtSupervisor.stop_all()
        ExtRegistry.reset()
        cleanup_config.()
        File.rm_rf!(extension_dir)
        :code.purge(extension_module)
        :code.delete(extension_module)
      end)

      loader_name = String.to_atom("loader_generation_reload_#{suffix}")
      {:ok, loader} = Loader.start_link(name: loader_name, config_home: config_home)
      assert Loader.load_error(loader) == nil
      assert {:ok, declared} = ExtRegistry.get(extension_name)

      assert {:ok, runtime_pid} =
               ExtSupervisor.start_extension(
                 Minga.Extension.Supervisor,
                 ExtRegistry,
                 extension_name,
                 declared
               )

      assert {:ok, admitted} = ExtRegistry.get(extension_name)
      assert admitted.pid == runtime_pid
      assert admitted.module == extension_module
      assert admitted.manifest.version == "1.0.0"
      assert File.read!(compile_log) == "1.0.0\n"

      File.write!(source_path, source.("2.0.0"))
      Minga.Events.subscribe(:extension_restart_required)

      assert {:error, message} = Loader.reload(loader)
      assert message =~ "Extension restart required before config reload"
      assert message =~ Atom.to_string(extension_name)

      assert_receive {:minga_event, :extension_restart_required,
                      %Minga.Events.ExtensionRestartRequiredEvent{
                        extension: ^extension_name,
                        reason: :source_changed
                      }}

      assert {:ok, unchanged} = ExtRegistry.get(extension_name)
      assert unchanged.pid == runtime_pid
      assert unchanged.module == extension_module
      assert unchanged.manifest.version == "1.0.0"
      assert File.read!(compile_log) == "1.0.0\n"

      runtime_supervisor =
        InstanceRegistry.via(InstanceRegistry, :runtime, extension_name)

      assert RuntimeSupervisor.local_child(runtime_supervisor) == {:ok, runtime_pid}
    end

    test "reload keeps using the injected config home across consecutive edits" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 3
        """)

      on_exit(cleanup)

      config_path = Path.join(minga_dir, "config.exs")
      gui_settings_path = Path.join(minga_dir, "gui_settings.exs")

      File.write!(gui_settings_path, """
      use Minga.Config
      set :line_numbers, :relative
      """)

      name = :"loader_reload_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)
      options_server = test_options_server()

      assert Options.get(options_server, :tab_width) == 3
      assert Options.get(options_server, :line_numbers) == :relative
      assert Loader.config_path(pid) == config_path
      assert Loader.gui_settings_path(pid) == gui_settings_path

      for tab_width <- [7, 5] do
        File.write!(config_path, """
        use Minga.Config
        set :tab_width, #{tab_width}
        """)

        assert :ok = Loader.reload(pid)
        assert Options.get(options_server, :tab_width) == tab_width
        assert Options.get(options_server, :line_numbers) == :relative
        assert Loader.config_path(pid) == config_path
        assert Loader.gui_settings_path(pid) == gui_settings_path
      end
    end

    test "reload rejects changed user modules and keeps admitted code resident" do
      {minga_dir, config_home, cleanup} = make_config_dir("")
      modules_dir = Path.join(minga_dir, "modules")
      File.mkdir_p!(modules_dir)

      module_path = Path.join(modules_dir, "reloadable.ex")

      admitted_source = """
      defmodule Minga.UserModules.Reloadable do
        def version, do: 1
      end
      """

      File.write!(module_path, admitted_source)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.UserModules.Reloadable)
        :code.delete(Minga.UserModules.Reloadable)
      end)

      name = :"loader_reload_mod_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)
      assert apply(Minga.UserModules.Reloadable, :version, []) == 1

      File.write!(module_path, """
      defmodule Minga.UserModules.Reloadable do
        def version, do: 2
      end
      """)

      assert {:error, "User module restart required before config reload"} = Loader.reload(pid)
      assert Loader.load_error(pid) == "User module restart required before config reload"
      assert Loader.loaded_modules(pid) == [Minga.UserModules.Reloadable]
      assert apply(Minga.UserModules.Reloadable, :version, []) == 1

      File.write!(module_path, admitted_source)
      assert :ok = Loader.reload(pid)
      assert Loader.load_error(pid) == nil
      assert Loader.loaded_modules(pid) == [Minga.UserModules.Reloadable]
    end

    test "reload clears stale user commands" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        command :my_custom, "Custom command" do
          :ok
        end
        """)

      on_exit(cleanup)

      name = :"loader_reload_cmd_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name, config_home: config_home)
      assert {:ok, _} = CommandRegistry.lookup(CommandRegistry, :my_custom)

      File.write!(Path.join(minga_dir, "config.exs"), """
      use Minga.Config
      set :tab_width, 2
      """)

      assert :ok = Loader.reload(name)
      assert :error = CommandRegistry.lookup(CommandRegistry, :my_custom)
    end

    test "reload returns error tuple when config has errors" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      on_exit(cleanup)

      name = :"loader_reload_err_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      # Break the config
      File.write!(Path.join(minga_dir, "config.exs"), """
      this is broken %%%
      """)

      message = "Extension declarations changed; restart Minga before config reload"
      assert {:error, ^message} = Loader.reload(pid)
      assert Loader.load_error(pid) == message
    end
  end

  describe "pdict bridge isolation" do
    test "Loader.start_link does not leak :minga_config_options into the caller pdict" do
      # The bridge mutations happen inside the Agent process running load_all,
      # not in the calling process. Verify nothing leaks back: the test's own
      # pdict value (set by setup) must be unchanged after Loader runs.
      {_dir, config_home, cleanup} = make_config_dir("")
      on_exit(cleanup)

      caller_before = Process.get(:minga_config_options)

      name = :"loader_pdict_isolation_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name, config_home: config_home)

      assert Process.get(:minga_config_options) == caller_before
    end

    test "user config raise during eval still completes the load with an error" do
      # The Loader's try/after restores the pdict bridge regardless of whether
      # eval_config_file's rescue caught the user-config raise. This test drives
      # the raise path and confirms (a) the loader still starts cleanly and
      # (b) the error is captured rather than crashing the Agent. If the bridge
      # had leaked, subsequent Loader.load_error/1 calls would fail.
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        raise "intentional config-eval failure"
        """)

      on_exit(cleanup)

      caller_before = Process.get(:minga_config_options)

      name = :"loader_raise_pdict_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      assert is_binary(Loader.load_error(pid))
      assert Process.get(:minga_config_options) == caller_before
    end
  end

  describe "apply_log_level (via Loader)" do
    test "raises Logger level when config sets a more restrictive level" do
      # apply_log_level/1 only applies the config value when it's *more*
      # restrictive than the current Logger level. Mix test config sets
      # :warning, so :error is :gt :warning and should be applied.
      original_level = Logger.level()
      Logger.configure(level: :info)

      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :log_level, :error
        """)

      on_exit(fn ->
        Logger.configure(level: original_level)
        cleanup.()
      end)

      name = :"loader_log_level_raise_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name, config_home: config_home)

      assert Logger.level() == :error
    end

    test "leaves Logger level alone when config is less restrictive than current" do
      original_level = Logger.level()
      Logger.configure(level: :error)

      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :log_level, :debug
        """)

      on_exit(fn ->
        Logger.configure(level: original_level)
        cleanup.()
      end)

      name = :"loader_log_level_keep_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name, config_home: config_home)

      # :debug is not :gt :error, so Logger.configure must not have been
      # called: the existing :error level wins.
      assert Logger.level() == :error
    end

    test "rescues ArgumentError when Options ETS table does not exist" do
      # Pointing the loader at a registered name with no backing ETS table
      # would otherwise crash apply_log_level/1 on :ets.lookup. The narrow
      # rescue keeps loader startup unaffected; everything else still runs.
      {_dir, config_home, cleanup} = make_config_dir("")
      on_exit(cleanup)

      name = :"loader_log_level_rescue_#{System.unique_integer([:positive])}"

      assert {:ok, _pid} =
               Loader.start_link(
                 name: name,
                 options_server: :nonexistent_options_server,
                 config_home: config_home
               )
    end
  end

  describe "--config CLI flag" do
    test "loader uses the custom config path when config_file flag is set" do
      custom_dir =
        Path.join(System.tmp_dir!(), "minga_custom_#{System.unique_integer([:positive])}")

      File.mkdir_p!(custom_dir)
      custom_path = Path.join(custom_dir, "my_config.exs")

      File.write!(custom_path, """
      use Minga.Config
      set :tab_width, 42
      """)

      # Also set up a standard XDG config with a different value so we can
      # confirm the custom one wins
      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_flags, %{
        view_mode: :auto,
        no_context: false,
        config_file: custom_path
      })

      on_exit(fn ->
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        Application.delete_env(:minga, :cli_startup_flags)
        cleanup.()
        File.rm_rf!(custom_dir)
      end)

      name = :"loader_custom_cfg_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      # The custom config should have been loaded (tab_width = 42)
      assert Options.get(test_options_server(), :tab_width) == 42
      # config_path should return the custom path
      assert Loader.config_path(pid) == custom_path
      # No load errors
      assert Loader.load_error(pid) == nil
    end

    test "nonexistent --config path warns in status bar but does not crash" do
      custom_path = "/tmp/minga_nonexistent_#{System.unique_integer([:positive])}.exs"

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_flags, %{
        view_mode: :auto,
        no_context: false,
        config_file: custom_path
      })

      empty_dir =
        Path.join(System.tmp_dir!(), "minga_empty_#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty_dir)

      on_exit(fn ->
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        Application.delete_env(:minga, :cli_startup_flags)
        File.rm_rf!(empty_dir)
      end)

      name = :"loader_missing_custom_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: empty_dir)

      # User explicitly requested a file that doesn't exist: warn them
      assert Loader.load_error(pid) =~ "Custom config not found"
      assert Loader.load_error(pid) =~ custom_path
      # config_path still reports the custom path
      assert Loader.config_path(pid) == custom_path
    end

    test "--config with non-.exs extension warns about potentially invalid file" do
      custom_dir =
        Path.join(System.tmp_dir!(), "minga_noexs_#{System.unique_integer([:positive])}")

      File.mkdir_p!(custom_dir)
      custom_path = Path.join(custom_dir, "my_config.txt")

      File.write!(custom_path, """
      use Minga.Config
      set :tab_width, 7
      """)

      {_dir, config_home, cleanup} = make_config_dir("")

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_flags, %{
        view_mode: :auto,
        no_context: false,
        config_file: custom_path
      })

      on_exit(fn ->
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        Application.delete_env(:minga, :cli_startup_flags)
        cleanup.()
        File.rm_rf!(custom_dir)
      end)

      name = :"loader_noexs_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      # The file was loaded (tab_width changed), but a warning is shown
      assert Options.get(test_options_server(), :tab_width) == 7
      assert Loader.load_error(pid) =~ "does not end in .exs"
      assert Loader.load_error(pid) =~ custom_path
    end

    test "project-local .minga.exs still loads after custom --config" do
      custom_dir =
        Path.join(System.tmp_dir!(), "minga_custom2_#{System.unique_integer([:positive])}")

      File.mkdir_p!(custom_dir)
      custom_path = Path.join(custom_dir, "my_config.exs")

      File.write!(custom_path, """
      use Minga.Config
      set :tab_width, 10
      """)

      # Set up XDG (even though it won't be used for global config)
      {_dir, config_home, cleanup} = make_config_dir("")

      # Create .minga.exs in a temp project dir
      project_dir =
        Path.join(System.tmp_dir!(), "minga_proj_custom_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      File.write!(Path.join(project_dir, ".minga.exs"), """
      use Minga.Config
      set :tab_width, 99
      """)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_flags, %{
        view_mode: :auto,
        no_context: false,
        config_file: custom_path
      })

      on_exit(fn ->
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        Application.delete_env(:minga, :cli_startup_flags)
        cleanup.()
        File.rm_rf!(custom_dir)
        File.rm_rf!(project_dir)
      end)

      name = :"loader_custom_proj_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

      # Project-local config overrides the custom global config (last writer wins)
      assert Options.get(test_options_server(), :tab_width) == 99
      assert Loader.project_config_error(pid) == nil
    end

    test "without --config flag, loader uses the default XDG path" do
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.delete_env(:minga, :cli_startup_flags)

      {_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 5
        """)

      on_exit(fn ->
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        Application.delete_env(:minga, :cli_startup_flags)
        cleanup.()
      end)

      name = :"loader_no_flag_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)

      assert Options.get(test_options_server(), :tab_width) == 5
      # config_path should be the standard XDG path
      assert Loader.config_path(pid) =~ "minga/config.exs"
    end

    test "reload preserves the custom config path" do
      custom_dir =
        Path.join(System.tmp_dir!(), "minga_reload_#{System.unique_integer([:positive])}")

      File.mkdir_p!(custom_dir)
      custom_path = Path.join(custom_dir, "my_config.exs")

      File.write!(custom_path, """
      use Minga.Config
      set :tab_width, 11
      """)

      {_dir, config_home, cleanup} = make_config_dir("")

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_flags, %{
        view_mode: :auto,
        no_context: false,
        config_file: custom_path
      })

      on_exit(fn ->
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        Application.delete_env(:minga, :cli_startup_flags)
        cleanup.()
        File.rm_rf!(custom_dir)
      end)

      name = :"loader_reload_custom_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)
      assert Options.get(test_options_server(), :tab_width) == 11

      # Change the custom config
      File.write!(custom_path, """
      use Minga.Config
      set :tab_width, 22
      """)

      assert :ok = Loader.reload(pid)
      assert Options.get(test_options_server(), :tab_width) == 22
      # Path should still be the custom one
      assert Loader.config_path(pid) == custom_path
    end
  end

  describe "safe mode" do
    test "skips user modules and all config eval stages" do
      {minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 42
        """)

      modules_dir = Path.join(minga_dir, "modules")
      File.mkdir_p!(modules_dir)

      File.write!(
        Path.join(modules_dir, "broken_module.ex"),
        "raise \"module should not compile\""
      )

      File.write!(
        Path.join(minga_dir, "gui_settings.exs"),
        "use Minga.Config\nset :tab_width, 43\n"
      )

      File.write!(Path.join(minga_dir, "after.exs"), "use Minga.Config\nset :tab_width, 44\n")

      project_dir =
        Path.join(System.tmp_dir!(), "minga_safe_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)
      File.write!(Path.join(project_dir, ".minga.exs"), "use Minga.Config\nset :tab_width, 45\n")

      Minga.SafeMode.put(true)

      on_exit(fn ->
        Minga.SafeMode.put(false)
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_safe_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loader.start_link(name: name, config_home: config_home, project_root: project_dir)

      assert Options.get(test_options_server(), :tab_width) == 2
      assert Loader.loaded_modules(pid) == []
      assert Loader.modules_errors(pid) == []
      assert Loader.load_error(pid) == nil
      assert Loader.project_config_error(pid) == nil
      assert Loader.gui_settings_error(pid) == nil
      assert Loader.after_error(pid) == nil
    end

    test "skips bundled extension registration and startup" do
      {_minga_dir, config_home, cleanup} = make_config_dir("use Minga.Config\n")
      previous_load_extensions = Application.get_env(:minga, :load_extensions)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :load_extensions, true)
      Minga.SafeMode.put(true)
      ensure_extension_runtime()

      on_exit(fn ->
        Minga.SafeMode.put(false)
        restore_application_env(:load_extensions, previous_load_extensions)
        cleanup.()
      end)

      name = :"loader_safe_extensions_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name, config_home: config_home)

      assert ExtRegistry.all() == []
    end

    test "reload loads user config even when startup safe mode remains active" do
      {_minga_dir, config_home, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 46
        """)

      Minga.SafeMode.put(true)

      on_exit(fn ->
        Minga.SafeMode.put(false)
        cleanup.()
      end)

      name = :"loader_safe_reload_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name, config_home: config_home)
      assert Options.get(test_options_server(), :tab_width) == 2

      assert :ok = Loader.reload(pid)
      assert Options.get(test_options_server(), :tab_width) == 46
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp assert_error_fragments(error, {:any, fragments}) do
    assert Enum.any?(fragments, &String.contains?(error, &1))
  end

  defp assert_error_fragments(error, {:all, fragments}) do
    for fragment <- fragments, do: assert(error =~ fragment)
  end

  # Creates a temporary directory structure that mimics XDG_CONFIG_HOME with
  # a minga/config.exs file. Returns `{minga_dir, config_home, cleanup_fn}`.
  # Pass `config_home` as `config_home:` to `Loader.start_link/1`.
  @spec make_config_dir(String.t()) :: {String.t(), String.t(), (-> :ok)}
  defp make_config_dir(config_content) do
    base = Path.join(System.tmp_dir!(), "minga_cfg_#{System.unique_integer([:positive])}")
    minga_dir = Path.join(base, "minga")
    File.mkdir_p!(minga_dir)
    File.write!(Path.join(minga_dir, "config.exs"), config_content)

    cleanup = fn ->
      File.rm_rf!(base)
    end

    {minga_dir, base, cleanup}
  end

  @spec restore_application_env(atom(), term()) :: :ok
  # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
  defp restore_application_env(key, nil), do: Application.delete_env(:minga, key)
  # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
  defp restore_application_env(key, value), do: Application.put_env(:minga, key, value)

  @spec ensure_extension_runtime() :: :ok
  defp ensure_extension_runtime do
    if Process.whereis(ExtRegistry) == nil do
      start_supervised!({ExtRegistry, name: ExtRegistry})
    end

    if Process.whereis(RootSupervisor) == nil do
      start_supervised!({ExtSupervisor, name: RootSupervisor})
    end

    ExtSupervisor.stop_all()
    ExtRegistry.reset()
    :ok
  end
end
