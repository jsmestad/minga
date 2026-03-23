defmodule Minga.Extension.SupervisorDslTest do
  use ExUnit.Case, async: true

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
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
