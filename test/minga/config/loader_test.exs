defmodule Minga.Config.LoaderTest do
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  # Not async: the project-local config tests call `File.cd!/1` to point the
  # loader at a temp project directory, but the BEAM cwd is process-global.
  # Running these in parallel with other compilation work breaks
  # `Code.compile_file/1` calls in unrelated suites. Per-test Options/Keymap
  # servers handle the singleton-isolation goal of #1448; the env-and-cwd
  # races are out of scope.
  use ExUnit.Case, async: false

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Config
  alias Minga.Config.Hooks
  alias Minga.Config.Loader
  alias Minga.Config.ModelineSegments
  alias Minga.Config.Options
  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Registry, as: ExtRegistry
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

  describe "config_path/1" do
    test "returns the resolved config path" do
      name = :"loader_path_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Agent.start_link(
          fn ->
            %{
              config_path: "/tmp/test.exs",
              load_error: nil,
              loaded_modules: [],
              modules_errors: [],
              project_config_path: nil,
              project_config_error: nil,
              after_error: nil
            }
          end,
          name: name
        )

      assert Loader.config_path(pid) == "/tmp/test.exs"
    end
  end

  describe "loading valid config" do
    test "applies set options from config file" do
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config

        set :tab_width, 4
        set :line_numbers, :relative
        """)

      on_exit(cleanup)

      name = :"loader_valid_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.load_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 4
      assert Options.get(test_options_server(), :line_numbers) == :relative
    end
  end

  test "starts extensions declared in project and after config after all config sources load" do
    {minga_dir, cleanup} =
      make_config_dir("""
      use Minga.Config

      set :tab_width, 2
      """)

    on_exit(cleanup)

    previous_load_extensions = Application.get_env(:minga, :load_extensions)
    Application.put_env(:minga, :load_extensions, true)

    on_exit(fn ->
      case previous_load_extensions do
        nil -> Application.delete_env(:minga, :load_extensions)
        value -> Application.put_env(:minga, :load_extensions, value)
      end
    end)

    ensure_extension_runtime()

    on_exit(fn ->
      ExtSupervisor.stop_all()
      ExtRegistry.reset()
    end)

    previous_cwd = File.cwd!()

    project_dir =
      Path.join(
        System.tmp_dir!(),
        "minga_project_extensions_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(project_dir)
    File.cd!(project_dir)

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
      File.cd!(previous_cwd)
      File.rm_rf!(project_dir)
      :code.purge(Minga.TestExtensions.ProjectConfigExt)
      :code.delete(Minga.TestExtensions.ProjectConfigExt)
      :code.purge(Minga.TestExtensions.AfterConfigExt)
      :code.delete(Minga.TestExtensions.AfterConfigExt)
    end)

    name = :"loader_project_after_ext_#{System.unique_integer([:positive])}"
    {:ok, pid} = Loader.start_link(name: name)

    assert Loader.load_error(pid) == nil
    assert {:ok, project_entry} = ExtRegistry.get(:project_config_ext)
    assert project_entry.status == :running
    assert Process.alive?(project_entry.pid)
    assert {:ok, after_entry} = ExtRegistry.get(:after_config_ext)
    assert after_entry.status == :running
    assert Process.alive?(after_entry.pid)
  end

  describe "loading LSP settings" do
    test "deep-merges user lsp_settings with server defaults" do
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config

        lsp_settings :mock_lsp,
          mock_lsp: [nested: [enabled: false], extra: true]
        """)

      on_exit(cleanup)

      name = :"loader_lsp_settings_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

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
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config

        lsp_settings :rust_analyzer, %{
          "rust-analyzer" => %{"cargo" => %{"allFeatures" => false}}
        }
        """)

      on_exit(cleanup)

      name = :"loader_lsp_section_keys_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

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
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config

        lsp_settings :mock_lsp, features: []
        """)

      on_exit(cleanup)

      name = :"loader_lsp_empty_list_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

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
        {_dir, cleanup} = make_config_dir(config)

        try do
          name = :"loader_#{label}_#{System.unique_integer([:positive])}"
          {:ok, pid} = Loader.start_link(name: name)

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

      previous_xdg_config_home = System.get_env("XDG_CONFIG_HOME")
      File.mkdir_p!(empty_dir)
      System.put_env("XDG_CONFIG_HOME", empty_dir)

      on_exit(fn ->
        restore_xdg_config_home(previous_xdg_config_home)
        File.rm_rf!(empty_dir)
      end)

      name = :"loader_missing_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.load_error(pid) == nil
    end
  end

  describe "user module compilation" do
    test "compiles valid modules from the modules directory" do
      {minga_dir, cleanup} = make_config_dir("")
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
      {:ok, pid} = Loader.start_link(name: name)

      assert Minga.UserModules.Greeter in Loader.loaded_modules(pid)
      assert apply(Minga.UserModules.Greeter, :hello, []) == "world"
      assert Loader.modules_errors(pid) == []
    end

    test "a compile error in one module does not prevent others from loading" do
      {minga_dir, cleanup} = make_config_dir("")
      modules_dir = Path.join(minga_dir, "modules")
      File.mkdir_p!(modules_dir)

      # Bad module (sorted first alphabetically)
      File.write!(Path.join(modules_dir, "aaa_bad.ex"), """
      defmodule Minga.UserModules.Bad do
        this is not valid %%%
      end
      """)

      # Good module (sorted second)
      File.write!(Path.join(modules_dir, "zzz_good.ex"), """
      defmodule Minga.UserModules.Good do
        def ok?, do: true
      end
      """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.UserModules.Good)
        :code.delete(Minga.UserModules.Good)
      end)

      name = :"loader_mixed_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Minga.UserModules.Good in Loader.loaded_modules(pid)
      assert apply(Minga.UserModules.Good, :ok?, []) == true
      assert length(Loader.modules_errors(pid)) == 1
      assert hd(Loader.modules_errors(pid)) =~ "aaa_bad.ex"
    end

    test "no error when modules directory does not exist" do
      {_dir, cleanup} = make_config_dir("")
      on_exit(cleanup)

      name = :"loader_no_modules_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.loaded_modules(pid) == []
      assert Loader.modules_errors(pid) == []
    end
  end

  describe "project-local config" do
    test ".minga.exs in cwd overrides global settings" do
      {_dir, cleanup} =
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

      original_cwd = File.cwd!()
      File.cd!(project_dir)

      on_exit(fn ->
        File.cd!(original_cwd)
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_project_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.project_config_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 8
    end

    test "no error when .minga.exs does not exist" do
      {_dir, cleanup} = make_config_dir("")

      # Use a temp dir with no .minga.exs
      project_dir =
        Path.join(System.tmp_dir!(), "minga_noproj_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)
      original_cwd = File.cwd!()
      File.cd!(project_dir)

      on_exit(fn ->
        File.cd!(original_cwd)
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_noproj_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.project_config_error(pid) == nil
    end
  end

  describe "gui_settings.exs" do
    test "overrides project config before after.exs" do
      {minga_dir, cleanup} =
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

      original_cwd = File.cwd!()
      File.cd!(project_dir)

      on_exit(fn ->
        File.cd!(original_cwd)
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_gui_settings_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.gui_settings_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 8
    end

    test "after.exs still overrides gui_settings.exs" do
      {minga_dir, cleanup} =
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

      original_cwd = File.cwd!()
      File.cd!(project_dir)

      on_exit(fn ->
        File.cd!(original_cwd)
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_gui_after_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.gui_settings_error(pid) == nil
      assert Loader.after_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 9
    end

    test "reload picks up gui_settings.exs changes with the same precedence" do
      {minga_dir, cleanup} =
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
      {:ok, pid} = Loader.start_link(name: name)
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
      {minga_dir, cleanup} =
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
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.gui_settings_error(pid) == nil
      assert Options.get(test_options_server(), :line_numbers) == :hybrid
      assert Options.explicitly_set?(test_options_server(), :line_numbers)

      gui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :native_gui}
      assert :ok = MingaEditor.Startup.apply_gui_defaults(gui_caps, test_options_server())
      assert Options.get(test_options_server(), :line_numbers) == :hybrid
    end

    test "gui_settings.exs default-valued selections override config.exs values" do
      {minga_dir, cleanup} =
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
      {:ok, pid} = Loader.start_link(name: name)

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
      {_minga_dir, cleanup} =
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

      original_cwd = File.cwd!()
      File.cd!(project_dir)

      on_exit(fn ->
        File.cd!(original_cwd)
        cleanup.()
        File.rm_rf!(project_dir)
      end)

      name = :"loader_non_gui_explicit_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.gui_settings_error(pid) == nil
      refute Options.explicitly_set?(test_options_server(), :line_numbers)
    end
  end

  describe "after.exs" do
    test "after.exs runs after config and can use user modules" do
      {minga_dir, cleanup} = make_config_dir("")
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
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.after_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 6
    end
  end

  describe "reload/1" do
    test "loads modeline_segment declarations from config" do
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config

        modeline_segment :loader_words, side: :left, priority: 42 do
          {" WORDS ", ctx.info_fg, ctx.bar_bg, [], nil}
        end
        """)

      on_exit(cleanup)

      name = :"loader_modeline_segment_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name)

      assert %{side: :left, priority: 42, source: :config} =
               ModelineSegments.lookup(:loader_words)
    end

    test "reload replaces stale config modeline segments" do
      {minga_dir, cleanup} =
        make_config_dir("""
        use Minga.Config

        modeline_segment :loader_stale_segment, side: :right do
          {" OLD ", ctx.info_fg, ctx.bar_bg, [], nil}
        end
        """)

      on_exit(cleanup)

      name = :"loader_reload_modeline_segment_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)
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
      ContributionCleanup.unregister_source(:config, keymap: ctx.keymap_server)

      {minga_dir, cleanup} =
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
        ContributionCleanup.unregister_source(:config, keymap: ctx.keymap_server)
        Theme.unregister_source(:config)
      end)

      name = :"loader_reload_registry_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

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
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      on_exit(cleanup)

      name = :"loader_reload_cleanup_failure_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)
      assert Loader.load_error(pid) == nil

      assert :ok =
               ContributionCleanup.register(:loader_reload_cleanup_failure, fn
                 :config -> raise "cleanup failure"
                 _source -> :ok
               end)

      on_exit(fn -> ContributionCleanup.unregister(:loader_reload_cleanup_failure) end)

      assert {:error, msg} = Loader.reload(pid)
      assert msg =~ "Config reload cleanup for :config failed"
      assert msg =~ "cleanup failure"
      assert Loader.load_error(pid) =~ "Config reload cleanup for :config failed"
    end

    test "reload surfaces stop_all failures instead of silently proceeding" do
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      on_exit(cleanup)

      ensure_extension_runtime()

      on_exit(fn ->
        ExtSupervisor.stop_all()
        ExtRegistry.reset()
      end)

      name = :"loader_reload_stop_all_failure_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)
      assert Loader.load_error(pid) == nil
      assert Options.get(test_options_server(), :tab_width) == 2

      bogus_pid =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      on_exit(fn ->
        if Process.alive?(bogus_pid) do
          Process.exit(bogus_pid, :kill)
        end
      end)

      ext_name = :loader_reload_stop_all_failure
      :ok = ExtRegistry.register(ext_name, "/tmp/loader_reload_stop_all_failure", [])
      :ok = ExtRegistry.update(ext_name, pid: bogus_pid, module: nil, status: :running)

      on_exit(fn -> ExtRegistry.unregister(ext_name) end)

      ext_dir =
        Path.join(
          System.tmp_dir!(),
          "minga_loader_reload_blocked_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ext_dir)

      File.write!(Path.join(ext_dir, "reload_blocked_ext.ex"), """
      defmodule Minga.TestExtensions.LoaderReloadBlockedExt do
        use Minga.Extension

        @impl true
        def name, do: :loader_reload_blocked_ext

        @impl true
        def description, do: "Reload blocked extension"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

      on_exit(fn ->
        File.rm_rf!(ext_dir)
        :code.purge(Minga.TestExtensions.LoaderReloadBlockedExt)
        :code.delete(Minga.TestExtensions.LoaderReloadBlockedExt)
      end)

      File.write!(Path.join(Path.dirname(Loader.config_path(pid)), "config.exs"), """
      use Minga.Config

      set :tab_width, 7
      extension :loader_reload_blocked_ext, path: #{inspect(ext_dir)}
      """)

      assert {:error, msg} = Loader.reload(pid)
      assert msg =~ "Extension stop_all failed"
      assert msg =~ "loader_reload_stop_all_failure"
      assert Loader.load_error(pid) =~ "Extension stop_all failed"
      assert Options.get(test_options_server(), :tab_width) == 2
      assert ExtRegistry.get(:loader_reload_blocked_ext) == :error
    end

    test "reload surfaces start_all failures with cleanup details" do
      {minga_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      on_exit(cleanup)

      previous_load_extensions = Application.get_env(:minga, :load_extensions)
      Application.put_env(:minga, :load_extensions, true)

      on_exit(fn ->
        case previous_load_extensions do
          nil -> Application.delete_env(:minga, :load_extensions)
          value -> Application.put_env(:minga, :load_extensions, value)
        end
      end)

      if Process.whereis(Minga.Extension.Supervisor) == nil do
        start_supervised!({Minga.Extension.Supervisor, name: Minga.Extension.Supervisor})
      end

      ext_dir =
        Path.join(
          System.tmp_dir!(),
          "minga_loader_start_all_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ext_dir)
      ext_path = Path.join(ext_dir, "start_all_failure.ex")
      ext_module = Minga.TestExtensions.LoaderStartAllFailure

      File.write!(
        ext_path,
        """
        defmodule #{ext_module} do
          use Minga.Extension

          @impl true
          def name, do: :loader_start_all_failure

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
        File.rm_rf!(ext_dir)
        :code.purge(ext_module)
        :code.delete(ext_module)
      end)

      cleanup_family =
        String.to_atom("loader_reload_start_all_cleanup_#{System.unique_integer([:positive])}")

      name = :"loader_reload_start_all_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)
      assert Loader.load_error(pid) == nil

      File.write!(
        Path.join(minga_dir, "config.exs"),
        """
        use Minga.Config
        extension :loader_start_all_failure, path: #{inspect(ext_dir)}
        """
      )

      assert :ok =
               ContributionCleanup.register(cleanup_family, fn
                 {:extension, :loader_start_all_failure} ->
                   raise "cleanup failure"

                 _source ->
                   :ok
               end)

      on_exit(fn -> ContributionCleanup.unregister(cleanup_family) end)

      assert {:error, msg} = Loader.reload(pid)
      assert msg =~ "Extension start_all failed"
      assert msg =~ "loader_start_all_failure"
      assert msg =~ "cleanup_failed"
      assert msg =~ "intentional_failure"
      assert msg =~ "cleanup failure"
      assert Loader.load_error(pid) =~ "Extension start_all failed"
    end

    test "reload picks up changed config values" do
      {minga_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 3
        """)

      on_exit(cleanup)

      name = :"loader_reload_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)
      assert Options.get(test_options_server(), :tab_width) == 3

      # Change the config file
      File.write!(Path.join(minga_dir, "config.exs"), """
      use Minga.Config
      set :tab_width, 7
      """)

      assert :ok = Loader.reload(pid)
      assert Options.get(test_options_server(), :tab_width) == 7
    end

    test "reload purges old user modules" do
      {minga_dir, cleanup} = make_config_dir("")
      modules_dir = Path.join(minga_dir, "modules")
      File.mkdir_p!(modules_dir)

      File.write!(Path.join(modules_dir, "reloadable.ex"), """
      defmodule Minga.UserModules.Reloadable do
        def version, do: 1
      end
      """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.UserModules.Reloadable)
        :code.delete(Minga.UserModules.Reloadable)
      end)

      name = :"loader_reload_mod_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)
      assert apply(Minga.UserModules.Reloadable, :version, []) == 1

      # Update the module
      File.write!(Path.join(modules_dir, "reloadable.ex"), """
      defmodule Minga.UserModules.Reloadable do
        def version, do: 2
      end
      """)

      assert :ok = Loader.reload(pid)
      assert apply(Minga.UserModules.Reloadable, :version, []) == 2
    end

    test "reload clears stale user commands" do
      {minga_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        command :my_custom, "Custom command" do
          :ok
        end
        """)

      on_exit(cleanup)

      name = :"loader_reload_cmd_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name)
      assert {:ok, _} = CommandRegistry.lookup(CommandRegistry, :my_custom)

      # Remove the command from config
      File.write!(Path.join(minga_dir, "config.exs"), """
      use Minga.Config
      set :tab_width, 2
      """)

      assert :ok = Loader.reload(name)
      assert :error = CommandRegistry.lookup(CommandRegistry, :my_custom)
    end

    test "reload returns error tuple when config has errors" do
      {minga_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      on_exit(cleanup)

      name = :"loader_reload_err_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      # Break the config
      File.write!(Path.join(minga_dir, "config.exs"), """
      this is broken %%%
      """)

      assert {:error, msg} = Loader.reload(pid)
      assert is_binary(msg)
    end
  end

  describe "pdict bridge isolation" do
    test "Loader.start_link does not leak :minga_config_options into the caller pdict" do
      # The bridge mutations happen inside the Agent process running load_all,
      # not in the calling process. Verify nothing leaks back: the test's own
      # pdict value (set by setup) must be unchanged after Loader runs.
      {_dir, cleanup} = make_config_dir("")
      on_exit(cleanup)

      caller_before = Process.get(:minga_config_options)

      name = :"loader_pdict_isolation_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name)

      assert Process.get(:minga_config_options) == caller_before
    end

    test "user config raise during eval still completes the load with an error" do
      # The Loader's try/after restores the pdict bridge regardless of whether
      # eval_config_file's rescue caught the user-config raise. This test drives
      # the raise path and confirms (a) the loader still starts cleanly and
      # (b) the error is captured rather than crashing the Agent. If the bridge
      # had leaked, subsequent Loader.load_error/1 calls would fail.
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        raise "intentional config-eval failure"
        """)

      on_exit(cleanup)

      caller_before = Process.get(:minga_config_options)

      name = :"loader_raise_pdict_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

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

      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :log_level, :error
        """)

      on_exit(fn ->
        Logger.configure(level: original_level)
        cleanup.()
      end)

      name = :"loader_log_level_raise_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name)

      assert Logger.level() == :error
    end

    test "leaves Logger level alone when config is less restrictive than current" do
      original_level = Logger.level()
      Logger.configure(level: :error)

      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :log_level, :debug
        """)

      on_exit(fn ->
        Logger.configure(level: original_level)
        cleanup.()
      end)

      name = :"loader_log_level_keep_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Loader.start_link(name: name)

      # :debug is not :gt :error, so Logger.configure must not have been
      # called: the existing :error level wins.
      assert Logger.level() == :error
    end

    test "rescues ArgumentError when Options ETS table does not exist" do
      # Pointing the loader at a registered name with no backing ETS table
      # would otherwise crash apply_log_level/1 on :ets.lookup. The narrow
      # rescue keeps loader startup unaffected; everything else still runs.
      {_dir, cleanup} = make_config_dir("")
      on_exit(cleanup)

      name = :"loader_log_level_rescue_#{System.unique_integer([:positive])}"

      assert {:ok, _pid} =
               Loader.start_link(name: name, options_server: :nonexistent_options_server)
    end
  end

  describe "--config CLI flag" do
    test "loader uses the custom config path when config_file flag is set" do
      # Create a custom config in a non-standard location
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
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 2
        """)

      # Set the CLI flag
      Application.put_env(:minga, :cli_startup_flags, %{
        view_mode: :auto,
        no_context: false,
        config_file: custom_path
      })

      on_exit(fn ->
        Application.delete_env(:minga, :cli_startup_flags)
        cleanup.()
        File.rm_rf!(custom_dir)
      end)

      name = :"loader_custom_cfg_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      # The custom config should have been loaded (tab_width = 42)
      assert Options.get(test_options_server(), :tab_width) == 42
      # config_path should return the custom path
      assert Loader.config_path(pid) == custom_path
      # No load errors
      assert Loader.load_error(pid) == nil
    end

    test "nonexistent --config path warns in status bar but does not crash" do
      custom_path = "/tmp/minga_nonexistent_#{System.unique_integer([:positive])}.exs"

      Application.put_env(:minga, :cli_startup_flags, %{
        view_mode: :auto,
        no_context: false,
        config_file: custom_path
      })

      # Set up XDG so the loader doesn't try to read a real config
      empty_dir =
        Path.join(System.tmp_dir!(), "minga_empty_#{System.unique_integer([:positive])}")

      previous_xdg_config_home = System.get_env("XDG_CONFIG_HOME")
      File.mkdir_p!(empty_dir)
      System.put_env("XDG_CONFIG_HOME", empty_dir)

      on_exit(fn ->
        Application.delete_env(:minga, :cli_startup_flags)
        restore_xdg_config_home(previous_xdg_config_home)
        File.rm_rf!(empty_dir)
      end)

      name = :"loader_missing_custom_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

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

      {_dir, cleanup} = make_config_dir("")

      Application.put_env(:minga, :cli_startup_flags, %{
        view_mode: :auto,
        no_context: false,
        config_file: custom_path
      })

      on_exit(fn ->
        Application.delete_env(:minga, :cli_startup_flags)
        cleanup.()
        File.rm_rf!(custom_dir)
      end)

      name = :"loader_noexs_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

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
      {_dir, cleanup} = make_config_dir("")

      # Create .minga.exs in a temp project dir
      project_dir =
        Path.join(System.tmp_dir!(), "minga_proj_custom_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      File.write!(Path.join(project_dir, ".minga.exs"), """
      use Minga.Config
      set :tab_width, 99
      """)

      original_cwd = File.cwd!()
      File.cd!(project_dir)

      Application.put_env(:minga, :cli_startup_flags, %{
        view_mode: :auto,
        no_context: false,
        config_file: custom_path
      })

      on_exit(fn ->
        File.cd!(original_cwd)
        Application.delete_env(:minga, :cli_startup_flags)
        cleanup.()
        File.rm_rf!(custom_dir)
        File.rm_rf!(project_dir)
      end)

      name = :"loader_custom_proj_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      # Project-local config overrides the custom global config (last writer wins)
      assert Options.get(test_options_server(), :tab_width) == 99
      assert Loader.project_config_error(pid) == nil
    end

    test "without --config flag, loader uses the default XDG path" do
      Application.delete_env(:minga, :cli_startup_flags)

      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 5
        """)

      on_exit(fn ->
        Application.delete_env(:minga, :cli_startup_flags)
        cleanup.()
      end)

      name = :"loader_no_flag_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

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

      {_dir, cleanup} = make_config_dir("")

      Application.put_env(:minga, :cli_startup_flags, %{
        view_mode: :auto,
        no_context: false,
        config_file: custom_path
      })

      on_exit(fn ->
        Application.delete_env(:minga, :cli_startup_flags)
        cleanup.()
        File.rm_rf!(custom_dir)
      end)

      name = :"loader_reload_custom_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)
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

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp assert_error_fragments(error, {:any, fragments}) do
    assert Enum.any?(fragments, &String.contains?(error, &1))
  end

  defp assert_error_fragments(error, {:all, fragments}) do
    for fragment <- fragments, do: assert(error =~ fragment)
  end

  # Creates a temporary directory structure that mimics XDG_CONFIG_HOME with
  # a minga/config.exs file. Returns `{minga_dir, cleanup_fn}`.
  @spec make_config_dir(String.t()) :: {String.t(), (-> :ok)}
  defp make_config_dir(config_content) do
    base = Path.join(System.tmp_dir!(), "minga_cfg_#{System.unique_integer([:positive])}")
    minga_dir = Path.join(base, "minga")
    File.mkdir_p!(minga_dir)
    File.write!(Path.join(minga_dir, "config.exs"), config_content)
    previous_xdg_config_home = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", base)

    # The per-test Options server started in setup is auto-cleaned by
    # start_supervised!, so no explicit reset is needed here.
    cleanup = fn ->
      restore_xdg_config_home(previous_xdg_config_home)
      File.rm_rf!(base)
    end

    {minga_dir, cleanup}
  end

  @spec restore_xdg_config_home(String.t() | nil) :: :ok
  defp restore_xdg_config_home(nil) do
    System.delete_env("XDG_CONFIG_HOME")
    :ok
  end

  defp restore_xdg_config_home(path) when is_binary(path) do
    System.put_env("XDG_CONFIG_HOME", path)
    :ok
  end

  @spec ensure_extension_runtime() :: :ok
  defp ensure_extension_runtime do
    if Process.whereis(ExtRegistry) == nil do
      start_supervised!({ExtRegistry, name: ExtRegistry})
    end

    if Process.whereis(Minga.Extension.Supervisor) == nil do
      start_supervised!({Minga.Extension.Supervisor, name: Minga.Extension.Supervisor})
    end

    ExtSupervisor.stop_all()
    ExtRegistry.reset()
    :ok
  end
end
