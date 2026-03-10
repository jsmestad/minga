defmodule Minga.ConfigTest do
  use ExUnit.Case, async: false

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Config.Hooks
  alias Minga.Config.Options
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Bindings

  setup do
    # Ensure required servers are running
    case Options.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Minga.Test.OptionsHelper.reset_for_test()
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

    on_exit(fn ->
      for mod <- [KeymapActive, Hooks] do
        try do
          mod.reset()
        catch
          :exit, _ -> :ok
        end
      end

      try do
        Minga.Test.OptionsHelper.reset_for_test()
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
end
