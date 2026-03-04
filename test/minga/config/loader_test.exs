defmodule Minga.Config.LoaderTest do
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  # Not async because we manipulate XDG_CONFIG_HOME and the global Options/Hooks/Keymap servers
  use ExUnit.Case, async: false

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Config.Hooks
  alias Minga.Config.Loader
  alias Minga.Config.Options
  alias Minga.Keymap.Store, as: KeymapStore

  setup do
    # Ensure all global servers are running (config eval needs them)
    for {mod, _} <- [{Options, nil}, {Hooks, nil}, {KeymapStore, nil}, {CommandRegistry, nil}] do
      case mod.start_link() do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> mod.reset()
      end
    end

    :ok
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
      assert Options.get(:tab_width) == 4
      assert Options.get(:line_numbers) == :relative
    end
  end

  describe "loading config with syntax error" do
    test "captures syntax error and stores it" do
      {_dir, cleanup} =
        make_config_dir("""
        this is not valid elixir %%%
        """)

      on_exit(cleanup)

      name = :"loader_syntax_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      error = Loader.load_error(pid)
      assert is_binary(error)
      assert error =~ "syntax" or error =~ "error" or error =~ "Error"
    end
  end

  describe "loading config with runtime error" do
    test "captures runtime error from invalid option value" do
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config

        set :tab_width, -1
        """)

      on_exit(cleanup)

      name = :"loader_runtime_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      error = Loader.load_error(pid)
      assert is_binary(error)
      assert error =~ "positive integer" or error =~ "error" or error =~ "Error"
    end
  end

  describe "missing config file" do
    test "no error when config file does not exist" do
      empty_dir =
        Path.join(System.tmp_dir!(), "minga_empty_#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty_dir)
      System.put_env("XDG_CONFIG_HOME", empty_dir)

      on_exit(fn ->
        System.delete_env("XDG_CONFIG_HOME")
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
      assert Options.get(:tab_width) == 8
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
      assert Options.get(:tab_width) == 6
    end
  end

  describe "reload/1" do
    test "reload picks up changed config values" do
      {minga_dir, cleanup} =
        make_config_dir("""
        use Minga.Config
        set :tab_width, 3
        """)

      on_exit(cleanup)

      name = :"loader_reload_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)
      assert Options.get(:tab_width) == 3

      # Change the config file
      File.write!(Path.join(minga_dir, "config.exs"), """
      use Minga.Config
      set :tab_width, 7
      """)

      assert :ok = Loader.reload(pid)
      assert Options.get(:tab_width) == 7
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

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Creates a temporary directory structure that mimics XDG_CONFIG_HOME with
  # a minga/config.exs file. Returns `{minga_dir, cleanup_fn}`.
  @spec make_config_dir(String.t()) :: {String.t(), (-> :ok)}
  defp make_config_dir(config_content) do
    base = Path.join(System.tmp_dir!(), "minga_cfg_#{System.unique_integer([:positive])}")
    minga_dir = Path.join(base, "minga")
    File.mkdir_p!(minga_dir)
    File.write!(Path.join(minga_dir, "config.exs"), config_content)
    System.put_env("XDG_CONFIG_HOME", base)

    cleanup = fn ->
      System.delete_env("XDG_CONFIG_HOME")
      File.rm_rf!(base)

      try do
        Options.reset()
      catch
        :exit, _ -> :ok
      end
    end

    {minga_dir, cleanup}
  end
end
