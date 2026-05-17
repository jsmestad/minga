defmodule Minga.Extension.SupervisorDslTest do
  use ExUnit.Case, async: true

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Config.ModelineSegments
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: KeymapActive

  setup do
    reg_name = :"ext_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ext_sup_#{System.unique_integer([:positive])}"
    cmd_reg_name = :"cmd_reg_#{System.unique_integer([:positive])}"
    keymap_name = :"keymap_#{System.unique_integer([:positive])}"

    {:ok, _} = ExtRegistry.start_link(name: reg_name)
    {:ok, _} = ExtSupervisor.start_link(name: sup_name)
    {:ok, _} = CommandRegistry.start_link(name: cmd_reg_name)
    {:ok, _} = KeymapActive.start_link(name: keymap_name)

    {:ok,
     registry: reg_name, supervisor: sup_name, command_registry: cmd_reg_name, keymap: keymap_name}
  end

  defp start_opts(ctx) do
    [command_registry: ctx.command_registry, keymap: ctx.keymap]
  end

  describe "DSL auto-registration" do
    test "commands declared with command/3 are registered in the command registry", ctx do
      {path, cleanup} =
        make_extension("DslCmds", """
        defmodule Minga.TestExtensions.DslCmds do
          use Minga.Extension

          command :dsl_test_cmd, "A DSL command",
            execute: {Minga.TestExtensions.DslCmds, :noop},
            requires_buffer: true

          command :dsl_test_cmd2, "Another DSL command",
            execute: {Minga.TestExtensions.DslCmds, :noop}

          @impl true
          def name, do: :dsl_cmds

          @impl true
          def description, do: "DSL command test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          @spec noop(map()) :: map()
          def noop(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.DslCmds)
        :code.delete(Minga.TestExtensions.DslCmds)
      end)

      :ok = ExtRegistry.register(ctx.registry, :dsl_cmds, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :dsl_cmds)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :dsl_cmds,
                 entry,
                 start_opts(ctx)
               )

      # Verify commands are in the isolated command registry
      assert {:ok, cmd} = CommandRegistry.lookup(ctx.command_registry, :dsl_test_cmd)
      assert cmd.name == :dsl_test_cmd
      assert cmd.description == "A DSL command"
      assert cmd.requires_buffer == true

      assert {:ok, cmd2} = CommandRegistry.lookup(ctx.command_registry, :dsl_test_cmd2)
      assert cmd2.name == :dsl_test_cmd2
      assert cmd2.requires_buffer == false

      # Verify the execute function works (calls the MFA)
      assert cmd.execute.(%{}) == %{}
    end

    test "commands are deregistered when extension is stopped", ctx do
      {path, cleanup} =
        make_extension("DslStop", """
        defmodule Minga.TestExtensions.DslStop do
          use Minga.Extension

          command :dsl_stop_cmd, "Will be removed",
            execute: {Minga.TestExtensions.DslStop, :noop}

          @impl true
          def name, do: :dsl_stop

          @impl true
          def description, do: "DSL stop test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          @spec noop(map()) :: map()
          def noop(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.DslStop)
        :code.delete(Minga.TestExtensions.DslStop)
      end)

      :ok = ExtRegistry.register(ctx.registry, :dsl_stop, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :dsl_stop)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :dsl_stop,
                 entry,
                 start_opts(ctx)
               )

      # Command is registered after start
      assert {:ok, _} = CommandRegistry.lookup(ctx.command_registry, :dsl_stop_cmd)

      # Stop the extension
      {:ok, running_entry} = ExtRegistry.get(ctx.registry, :dsl_stop)

      :ok =
        ExtSupervisor.stop_extension(
          ctx.supervisor,
          ctx.registry,
          :dsl_stop,
          running_entry,
          start_opts(ctx)
        )

      # Command is deregistered after stop
      assert :error = CommandRegistry.lookup(ctx.command_registry, :dsl_stop_cmd)
    end

    test "keybindings declared with keybind/4 are registered in the keymap", ctx do
      {path, cleanup} =
        make_extension("DslBinds", """
        defmodule Minga.TestExtensions.DslBinds do
          use Minga.Extension

          command :dsl_bind_cmd, "Bindable command",
            execute: {Minga.TestExtensions.DslBinds, :noop}

          keybind :normal, "SPC m z", :dsl_bind_cmd, "DSL bind test"

          @impl true
          def name, do: :dsl_binds

          @impl true
          def description, do: "DSL keybind test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          @spec noop(map()) :: map()
          def noop(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.DslBinds)
        :code.delete(Minga.TestExtensions.DslBinds)
      end)

      :ok = ExtRegistry.register(ctx.registry, :dsl_binds, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :dsl_binds)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :dsl_binds,
                 entry,
                 start_opts(ctx)
               )

      # Verify the keybinding landed in the isolated keymap's leader trie
      leader_trie = KeymapActive.leader_trie(ctx.keymap)
      {:ok, keys} = Minga.Keymap.KeyParser.parse("m z")

      assert {:command, :dsl_bind_cmd, _desc} =
               Minga.Keymap.Bindings.lookup_sequence(leader_trie, keys)
    end

    test "keybindings are deregistered when extension is stopped", ctx do
      {path, cleanup} =
        make_extension("DslUnbind", """
        defmodule Minga.TestExtensions.DslUnbind do
          use Minga.Extension

          command :dsl_unbind_cmd, "Will be unbound",
            execute: {Minga.TestExtensions.DslUnbind, :noop}

          keybind :normal, "SPC m y", :dsl_unbind_cmd, "DSL unbind test"

          @impl true
          def name, do: :dsl_unbind

          @impl true
          def description, do: "DSL unbind test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          @spec noop(map()) :: map()
          def noop(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.DslUnbind)
        :code.delete(Minga.TestExtensions.DslUnbind)
      end)

      :ok = ExtRegistry.register(ctx.registry, :dsl_unbind, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :dsl_unbind)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :dsl_unbind,
                 entry,
                 start_opts(ctx)
               )

      # Keybinding exists after start
      leader_trie = KeymapActive.leader_trie(ctx.keymap)
      {:ok, keys} = Minga.Keymap.KeyParser.parse("m y")

      assert {:command, :dsl_unbind_cmd, _desc} =
               Minga.Keymap.Bindings.lookup_sequence(leader_trie, keys)

      # Stop the extension
      {:ok, running_entry} = ExtRegistry.get(ctx.registry, :dsl_unbind)

      :ok =
        ExtSupervisor.stop_extension(
          ctx.supervisor,
          ctx.registry,
          :dsl_unbind,
          running_entry,
          start_opts(ctx)
        )

      # Keybinding is gone after stop
      leader_trie = KeymapActive.leader_trie(ctx.keymap)

      assert :not_found = Minga.Keymap.Bindings.lookup_sequence(leader_trie, keys)
    end

    test "modeline segments declared with modeline_segment/3 are registered and removed", ctx do
      ModelineSegments.unregister(:dsl_modeline_words)

      {path, cleanup} =
        make_extension("DslModeline", """
        defmodule Minga.TestExtensions.DslModeline do
          use Minga.Extension

          modeline_segment :dsl_modeline_words, side: :right, priority: 55 do
            {" DSL ", ctx.info_fg, ctx.bar_bg, [], nil}
          end

          @impl true
          def name, do: :dsl_modeline

          @impl true
          def description, do: "DSL modeline test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        ModelineSegments.unregister(:dsl_modeline_words)
        :code.purge(Minga.TestExtensions.DslModeline)
        :code.delete(Minga.TestExtensions.DslModeline)
      end)

      :ok = ExtRegistry.register(ctx.registry, :dsl_modeline, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :dsl_modeline)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :dsl_modeline,
                 entry,
                 start_opts(ctx)
               )

      assert %{name: :dsl_modeline_words, side: :right, priority: 55} =
               ModelineSegments.lookup(:dsl_modeline_words)

      {:ok, running_entry} = ExtRegistry.get(ctx.registry, :dsl_modeline)

      :ok =
        ExtSupervisor.stop_extension(
          ctx.supervisor,
          ctx.registry,
          :dsl_modeline,
          running_entry,
          start_opts(ctx)
        )

      assert ModelineSegments.lookup(:dsl_modeline_words) == nil
    end

    test "invalid modeline segment declarations fail extension startup", ctx do
      {path, cleanup} =
        make_extension("DslBadModeline", """
        defmodule Minga.TestExtensions.DslBadModeline do
          use Minga.Extension

          modeline_segment :dsl_bad_modeline, side: :middle do
            {" BAD ", ctx.info_fg, ctx.bar_bg, [], nil}
          end

          @impl true
          def name, do: :dsl_bad_modeline

          @impl true
          def description, do: "Bad DSL modeline test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.DslBadModeline)
        :code.delete(Minga.TestExtensions.DslBadModeline)
      end)

      :ok = ExtRegistry.register(ctx.registry, :dsl_bad_modeline, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :dsl_bad_modeline)

      assert {:error, {:modeline_segment_rejected, :dsl_bad_modeline, {:invalid_side, :middle}}} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :dsl_bad_modeline,
                 entry,
                 start_opts(ctx)
               )

      assert ModelineSegments.lookup(:dsl_bad_modeline) == nil

      assert {:ok, %{status: :load_error, pid: nil}} =
               ExtRegistry.get(ctx.registry, :dsl_bad_modeline)
    end

    test "modeline registration failure leaves no commands, keybindings, or child process", ctx do
      {path, cleanup} =
        make_extension("DslBadModelineTransactional", """
        defmodule Minga.TestExtensions.DslBadModelineTransactional do
          use Minga.Extension

          command :dsl_bad_modeline_cmd, "Must not remain active",
            execute: {Minga.TestExtensions.DslBadModelineTransactional, :noop}

          keybind :normal, "SPC m b", :dsl_bad_modeline_cmd, "Must not remain bound"

          modeline_segment :mode, side: :left do
            {" BAD ", ctx.info_fg, ctx.bar_bg, [], nil}
          end

          @impl true
          def name, do: :dsl_bad_modeline_transactional

          @impl true
          def description, do: "Bad DSL modeline transaction test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          @spec noop(map()) :: map()
          def noop(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.DslBadModelineTransactional)
        :code.delete(Minga.TestExtensions.DslBadModelineTransactional)
      end)

      :ok = ExtRegistry.register(ctx.registry, :dsl_bad_modeline_transactional, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :dsl_bad_modeline_transactional)

      assert {:error, {:modeline_segment_rejected, :mode, {:reserved_name, :mode}}} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :dsl_bad_modeline_transactional,
                 entry,
                 start_opts(ctx)
               )

      assert :error = CommandRegistry.lookup(ctx.command_registry, :dsl_bad_modeline_cmd)
      leader_trie = KeymapActive.leader_trie(ctx.keymap)
      {:ok, keys} = Minga.Keymap.KeyParser.parse("m b")
      assert :not_found = Minga.Keymap.Bindings.lookup_sequence(leader_trie, keys)

      assert ModelineSegments.lookup(:mode) == nil
      assert DynamicSupervisor.count_children(ctx.supervisor).active == 0

      assert {:ok, %{status: :load_error, pid: nil}} =
               ExtRegistry.get(ctx.registry, :dsl_bad_modeline_transactional)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec make_extension(String.t(), String.t()) :: {String.t(), (-> :ok)}
  defp make_extension(dir_name, source) do
    dir =
      Path.join(System.tmp_dir!(), "minga_ext_#{dir_name}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "extension.ex"), source)

    cleanup = fn -> File.rm_rf!(dir) end
    {dir, cleanup}
  end
end
