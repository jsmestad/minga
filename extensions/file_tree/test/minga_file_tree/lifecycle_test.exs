defmodule MingaFileTree.LifecycleTest do
  @moduledoc """
  Lifecycle coverage for the bundled FileTree extension package.
  """
  # Exercises global sidebar/input/scope registries and extension module reloads.
  use ExUnit.Case, async: false

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: ActiveKeymap
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.KeyParser
  alias Minga.Keymap.Scope
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Input

  @source {:extension, :minga_file_tree}

  setup do
    cleanup_file_tree_contributions()

    on_exit(fn ->
      cleanup_file_tree_contributions()
    end)

    :ok
  end

  test "reload terminates the old child and replaces source-owned contributions without duplicates" do
    ctx = start_lifecycle_context()

    first_pid = start_file_tree!(ctx)
    assert_file_tree_contributions_registered(ctx)

    ref = Process.monitor(first_pid)
    stop_file_tree!(ctx)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}, 1_000
    assert_file_tree_contributions_removed(ctx)

    second_pid = start_file_tree!(ctx)
    assert second_pid != first_pid
    assert_file_tree_contributions_registered(ctx)
    assert Enum.count(Input.surface_handlers(), &(&1 == MingaFileTree.Input.Handler)) == 1

    second_ref = Process.monitor(second_pid)
    stop_file_tree!(ctx)
    assert_receive {:DOWN, ^second_ref, :process, ^second_pid, _reason}, 1_000
    assert_file_tree_contributions_removed(ctx)
  end

  defp start_lifecycle_context do
    supervisor = start_supervised!({ExtSupervisor, name: unique_name("file_tree_ext_sup")})
    registry = start_supervised!({ExtRegistry, name: unique_name("file_tree_ext_registry")})

    command_registry =
      start_supervised!({CommandRegistry, name: unique_name("file_tree_command_registry")})

    keymap = start_supervised!({ActiveKeymap, name: nil})
    path = Path.expand("../../lib", __DIR__)

    :ok = ExtRegistry.register(registry, :minga_file_tree, path, [])

    %{
      supervisor: supervisor,
      registry: registry,
      command_registry: command_registry,
      keymap: keymap
    }
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp start_file_tree!(ctx) do
    {:ok, entry} = ExtRegistry.get(ctx.registry, :minga_file_tree)

    assert {:ok, pid} =
             ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :minga_file_tree, entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    pid
  end

  defp stop_file_tree!(ctx) do
    {:ok, entry} = ExtRegistry.get(ctx.registry, :minga_file_tree)

    assert :ok =
             ExtSupervisor.stop_extension(ctx.supervisor, ctx.registry, :minga_file_tree, entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )
  end

  defp assert_file_tree_contributions_registered(ctx) do
    assert {:ok, _command} = CommandRegistry.lookup(ctx.command_registry, :toggle_file_tree)
    assert {:command, :toggle_file_tree, _description} = lookup_file_tree_keybind(ctx.keymap)
    assert Scope.module_for(:file_tree) == MingaFileTree.Keymap.Scope
    assert Enum.member?(Input.surface_handlers(), MingaFileTree.Input.Handler)

    assert %{
             source: @source,
             semantic_kind: "file_tree",
             input_handler: MingaFileTree.Input.Handler
           } = Sidebar.get("file_tree")
  end

  defp assert_file_tree_contributions_removed(ctx) do
    assert :error = CommandRegistry.lookup(ctx.command_registry, :toggle_file_tree)
    assert :not_found = lookup_file_tree_keybind(ctx.keymap)
    assert Scope.module_for(:file_tree) == nil
    refute Enum.member?(Input.surface_handlers(), MingaFileTree.Input.Handler)
    assert Sidebar.get("file_tree") == nil
  end

  defp lookup_file_tree_keybind(keymap) do
    {:ok, keys} = KeyParser.parse("o p")

    keymap
    |> ActiveKeymap.leader_trie()
    |> Bindings.lookup_sequence(keys)
  end

  defp cleanup_file_tree_contributions do
    :ok = CommandRegistry.unregister_source(@source)
    :ok = ActiveKeymap.unregister_source(@source)
    :ok = Scope.unregister_source(@source)
    :ok = Input.unregister_source(@source)
    :ok = Sidebar.unregister_source(@source)
  end
end
