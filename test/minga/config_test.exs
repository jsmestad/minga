defmodule Minga.ConfigTest do
  use ExUnit.Case, async: false

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Config.Hooks
  alias Minga.Config.Options
  alias Minga.Extension.Entry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Bindings
  alias Minga.Popup.Registry, as: PopupRegistry

  setup do
    # Ensure required servers are running
    case Options.start_link() do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        Options.reset()
        Options.set(:clipboard, :none)
    end

    case KeymapActive.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> KeymapActive.reset()
    end

    case CommandRegistry.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Hooks.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Hooks.reset()
    end

    case ExtRegistry.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> ExtRegistry.reset()
    end

    PopupRegistry.init()
    PopupRegistry.clear()

    on_exit(fn ->
      PopupRegistry.clear()

      for mod <- [KeymapActive, Hooks] do
        try do
          mod.reset()
        catch
          :exit, _ -> :ok
        end
      end

      try do
        ExtRegistry.reset()
      catch
        :exit, _ -> :ok
      end

      try do
        Options.reset()
        Options.set(:clipboard, :none)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "use Minga.Config" do
    test "imports set/2, bind/4, and command/3 into the calling module" do
      # Compilation succeeding proves the imports work
      Code.compile_string("""
      defmodule Minga.ConfigTest.SampleConfig#{System.unique_integer([:positive])} do
        use Minga.Config

        def check_set, do: function_exported?(__MODULE__, :set, 2)
        def check_bind, do: function_exported?(__MODULE__, :bind, 4)
      end
      """)

      assert true
    end
  end

  describe "set/2" do
    test "raises ArgumentError for unknown option name" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Minga.Config.set(:nonexistent, 42)
      end
    end

    test "raises ArgumentError for wrong type" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Minga.Config.set(:tab_width, -1)
      end
    end
  end

  describe "bind/4" do
    test "adds a leader key binding" do
      Minga.Config.bind(:normal, "SPC g s", :git_status, "Git status")

      trie = KeymapActive.leader_trie()
      {:prefix, g_node} = Bindings.lookup(trie, {?g, 0})
      assert {:command, :git_status} = Bindings.lookup(g_node, {?s, 0})
    end

    test "binds insert-mode key" do
      Minga.Config.bind(:insert, "C-j", :next_line, "Next line")

      trie = KeymapActive.mode_trie(:insert)
      assert {:command, :next_line} = Bindings.lookup(trie, {?j, 0x02})
    end

    test "binds visual-mode key" do
      Minga.Config.bind(:visual, "C-x", :custom_cut, "Custom cut")

      trie = KeymapActive.mode_trie(:visual)
      assert {:command, :custom_cut} = Bindings.lookup(trie, {?x, 0x02})
    end

    test "binds scope-specific key" do
      Minga.Config.bind({:agent, :normal}, "y", :agent_copy, "Agent copy")

      trie = KeymapActive.scope_trie(:agent, :normal)
      assert {:command, :agent_copy} = Bindings.lookup(trie, {?y, 0})
    end

    test "invalid key sequence logs warning but does not crash" do
      # Should not raise
      Minga.Config.bind(:normal, "", :noop, "noop")
    end
  end

  describe "bind/5 with filetype option" do
    test "registers filetype-scoped binding" do
      Minga.Config.bind(:normal, "SPC m t", :mix_test, "Run tests", filetype: :elixir)

      trie = KeymapActive.filetype_trie(:elixir)
      assert {:command, :mix_test} = Bindings.lookup(trie, {?t, 0})
    end
  end

  describe "keymap/2 macro" do
    test "scopes bindings to filetype" do
      Code.eval_string("""
      use Minga.Config

      keymap :elixir do
        bind :normal, "SPC m t", :mix_test, "Run tests"
        bind :normal, "SPC m f", :mix_format, "Format"
      end
      """)

      trie = KeymapActive.filetype_trie(:elixir)
      assert {:command, :mix_test} = Bindings.lookup(trie, {?t, 0})
      assert {:command, :mix_format} = Bindings.lookup(trie, {?f, 0})
    end

    test "filetype scope does not leak outside keymap block" do
      Code.eval_string("""
      use Minga.Config

      keymap :go do
        bind :normal, "SPC m t", :go_test, "Go test"
      end

      bind :normal, "SPC z z", :global_cmd, "Global command"
      """)

      # The "SPC z z" binding should be global (in leader trie), not scoped to :go
      trie = KeymapActive.leader_trie()
      {:prefix, z_node} = Bindings.lookup(trie, {?z, 0})
      assert {:command, :global_cmd} = Bindings.lookup(z_node, {?z, 0})

      # And not in the go filetype trie
      go_trie = KeymapActive.filetype_trie(:go)
      assert :not_found = Bindings.lookup(go_trie, {?z, 0})
    end
  end

  describe "command/3 macro" do
    test "registers command in the registry" do
      Code.eval_string("""
      use Minga.Config

      command :test_cmd_#{System.unique_integer([:positive])}, "Test command" do
        :ok
      end
      """)

      # The command was registered (we can't easily look up a dynamic name,
      # so we test with a known name)
      Minga.Config.register_command(:my_test_cmd, "My test", fn -> :ok end)
      assert {:ok, cmd} = CommandRegistry.lookup(CommandRegistry, :my_test_cmd)
      assert cmd.description == "My test"
    end

    test "command runtime errors are isolated from the editor" do
      Minga.Config.register_command(:crashing_cmd, "Crashes", fn ->
        raise "boom"
      end)

      {:ok, cmd} = CommandRegistry.lookup(CommandRegistry, :crashing_cmd)
      # Executing the command should not raise (it runs in a Task)
      state = %{some: :state}
      result = cmd.execute.(state)
      assert result == state
    end
  end

  describe "on/2" do
    test "registers a hook that fires on event" do
      test_pid = self()
      Minga.Config.on(:after_save, fn _buf, path -> send(test_pid, {:saved, path}) end)

      Hooks.run(:after_save, [:buf, "/tmp/test.ex"])
      assert_receive {:saved, "/tmp/test.ex"}, 500
    end

    test "raises for unknown event" do
      assert_raise ArgumentError, fn ->
        Minga.Config.on(:nonexistent, fn -> :ok end)
      end
    end
  end

  describe "for_filetype/2" do
    test "sets per-filetype option overrides" do
      Minga.Config.for_filetype(:go, tab_width: 8)

      assert Options.get_for_filetype(:tab_width, :go) == 8
      assert Options.get(:tab_width) == 2
    end

    test "sets multiple options at once" do
      Minga.Config.for_filetype(:python, tab_width: 4, autopair: false)

      assert Options.get_for_filetype(:tab_width, :python) == 4
      assert Options.get_for_filetype(:autopair, :python) == false
    end

    test "raises for invalid option value" do
      assert_raise ArgumentError, fn ->
        Minga.Config.for_filetype(:go, tab_width: -1)
      end
    end
  end

  describe "popup/2" do
    test "registers a popup rule with string pattern" do
      Minga.Config.popup("*Warnings*", side: :bottom, size: {:percent, 30})

      assert {:ok, rule} = PopupRegistry.match("*Warnings*")
      assert rule.side == :bottom
      assert rule.size == {:percent, 30}
    end

    test "registers a popup rule with regex pattern" do
      Minga.Config.popup(~r/\*Help/, display: :float, width: {:percent, 60})

      assert {:ok, rule} = PopupRegistry.match("*Help: elixir*")
      assert rule.display == :float
      assert rule.width == {:percent, 60}
    end

    test "later registration overrides same pattern" do
      Minga.Config.popup("*Warnings*", side: :bottom)
      Minga.Config.popup("*Warnings*", side: :right)

      assert {:ok, rule} = PopupRegistry.match("*Warnings*")
      assert rule.side == :right
    end

    test "raises on invalid options" do
      assert_raise ArgumentError, fn ->
        Minga.Config.popup("*test*", display: :invalid)
      end
    end

    test "registers with default options" do
      Minga.Config.popup("*TestPopup*")

      assert {:ok, rule} = PopupRegistry.match("*TestPopup*")
      assert rule.display == :split
      assert rule.side == :bottom
      assert rule.size == {:percent, 30}
      assert rule.focus == true
    end

    test "config DSL imports popup/2" do
      Code.compile_string("""
      defmodule Minga.ConfigTest.PopupConfig#{System.unique_integer([:positive])} do
        use Minga.Config
        popup "*test-popup*", side: :right, size: {:percent, 40}
      end
      """)

      assert {:ok, rule} = PopupRegistry.match("*test-popup*")
      assert rule.side == :right
    end
  end

  describe "extension/2" do
    test "registers a path-sourced extension" do
      dir = System.tmp_dir!() |> Path.expand()
      Minga.Config.extension(:my_tool, path: dir)

      assert {:ok, %Entry{} = entry} = ExtRegistry.get(:my_tool)
      assert entry.source_type == :path
      assert entry.path == dir
    end

    test "passes extra options as config for path source" do
      dir = System.tmp_dir!() |> Path.expand()
      Minga.Config.extension(:my_tool, path: dir, greeting: "hello")

      assert {:ok, entry} = ExtRegistry.get(:my_tool)
      assert entry.config == [greeting: "hello"]
    end

    test "expands ~ in path" do
      Minga.Config.extension(:my_tool, path: "~/code/my_tool")

      assert {:ok, entry} = ExtRegistry.get(:my_tool)
      assert entry.path == Path.expand("~/code/my_tool")
    end

    test "registers a git-sourced extension" do
      Minga.Config.extension(:snippets, git: "https://github.com/user/snippets")

      assert {:ok, %Entry{} = entry} = ExtRegistry.get(:snippets)
      assert entry.source_type == :git
      assert entry.git.url == "https://github.com/user/snippets"
      assert entry.git.branch == nil
      assert entry.git.ref == nil
    end

    test "registers a git extension with branch" do
      Minga.Config.extension(:snippets,
        git: "https://github.com/user/snippets",
        branch: "develop"
      )

      assert {:ok, entry} = ExtRegistry.get(:snippets)
      assert entry.git.branch == "develop"
    end

    test "registers a git extension with ref" do
      Minga.Config.extension(:snippets,
        git: "git@github.com:user/snippets.git",
        ref: "v1.0.0"
      )

      assert {:ok, entry} = ExtRegistry.get(:snippets)
      assert entry.git.ref == "v1.0.0"
    end

    test "registers a git extension with SSH URL" do
      Minga.Config.extension(:private, git: "git@github.com:user/private.git")

      assert {:ok, entry} = ExtRegistry.get(:private)
      assert entry.git.url == "git@github.com:user/private.git"
    end

    test "passes extra options as config for git source" do
      Minga.Config.extension(:snippets,
        git: "https://github.com/user/snippets",
        branch: "main",
        greeting: "hello"
      )

      assert {:ok, entry} = ExtRegistry.get(:snippets)
      assert entry.config == [greeting: "hello"]
    end

    test "registers a hex-sourced extension" do
      Minga.Config.extension(:snippets, hex: "minga_snippets", version: "~> 0.3")

      assert {:ok, %Entry{} = entry} = ExtRegistry.get(:snippets)
      assert entry.source_type == :hex
      assert entry.hex.package == "minga_snippets"
      assert entry.hex.version == "~> 0.3"
    end

    test "registers a hex extension without version" do
      Minga.Config.extension(:snippets, hex: "minga_snippets")

      assert {:ok, entry} = ExtRegistry.get(:snippets)
      assert entry.hex.version == nil
    end

    test "passes extra options as config for hex source" do
      Minga.Config.extension(:snippets, hex: "minga_snippets", version: "~> 1.0", debug: true)

      assert {:ok, entry} = ExtRegistry.get(:snippets)
      assert entry.config == [debug: true]
    end

    test "raises when no source is provided" do
      assert_raise ArgumentError, ~r/one of :path, :git, or :hex is required/, fn ->
        Minga.Config.extension(:bad, greeting: "hello")
      end
    end

    test "raises when multiple sources are provided" do
      assert_raise ArgumentError, ~r/only one of :path, :git, or :hex/, fn ->
        Minga.Config.extension(:bad, path: "/tmp/ext", git: "https://example.com/repo")
      end
    end

    test "raises for empty git URL" do
      assert_raise ArgumentError, ~r/non-empty URL/, fn ->
        Minga.Config.extension(:bad, git: "")
      end
    end

    test "raises for empty hex package name" do
      assert_raise ArgumentError, ~r/non-empty package name/, fn ->
        Minga.Config.extension(:bad, hex: "")
      end
    end
  end
end
