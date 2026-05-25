defmodule MingaGitPorcelain.LifecycleTest do
  @moduledoc """
  Lifecycle coverage for the bundled Git porcelain extension package.
  """

  # Exercises global input/scope registries and extension module reloads.
  use ExUnit.Case, async: false

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: ActiveKeymap
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.KeyParser
  alias Minga.Keymap.Scope
  alias MingaEditor.Input

  @source {:extension, :minga_git_porcelain}

  setup do
    cleanup_git_porcelain_contributions()

    on_exit(fn ->
      cleanup_git_porcelain_contributions()
    end)

    :ok
  end

  test "reload terminates the old child and replaces source-owned contributions without duplicates" do
    ctx = start_lifecycle_context()

    first_pid = start_git_porcelain!(ctx)
    assert_git_porcelain_contributions_registered(ctx)

    ref = Process.monitor(first_pid)
    stop_git_porcelain!(ctx)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}, 1_000
    assert_git_porcelain_contributions_removed(ctx)

    second_pid = start_git_porcelain!(ctx)
    assert second_pid != first_pid
    assert_git_porcelain_contributions_registered(ctx)
    assert Enum.count(Input.surface_handlers(), &(&1 == MingaGitPorcelain.Input.GitStatus)) == 1

    second_ref = Process.monitor(second_pid)
    stop_git_porcelain!(ctx)
    assert_receive {:DOWN, ^second_ref, :process, ^second_pid, _reason}, 1_000
    assert_git_porcelain_contributions_removed(ctx)
  end

  defp start_lifecycle_context do
    supervisor = start_supervised!({ExtSupervisor, name: unique_name("git_porcelain_ext_sup")})
    registry = start_supervised!({ExtRegistry, name: unique_name("git_porcelain_ext_registry")})

    command_registry =
      start_supervised!({CommandRegistry, name: unique_name("git_porcelain_command_registry")})

    keymap = start_supervised!({ActiveKeymap, name: nil})
    path = Path.expand("../../lib", __DIR__)

    :ok = ExtRegistry.register(registry, :minga_git_porcelain, path, [])

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

  defp start_git_porcelain!(ctx) do
    {:ok, entry} = ExtRegistry.get(ctx.registry, :minga_git_porcelain)

    assert {:ok, pid} =
             ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :minga_git_porcelain, entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    pid
  end

  defp stop_git_porcelain!(ctx) do
    {:ok, entry} = ExtRegistry.get(ctx.registry, :minga_git_porcelain)

    assert :ok =
             ExtSupervisor.stop_extension(ctx.supervisor, ctx.registry, :minga_git_porcelain, entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )
  end

  defp assert_git_porcelain_contributions_registered(ctx) do
    assert {:ok, _command} = CommandRegistry.lookup(ctx.command_registry, :git_status_toggle)
    assert {:ok, _command} = CommandRegistry.lookup(ctx.command_registry, :git_blame_line)
    assert {:command, :git_status_toggle, _description} = lookup_git_status_keybind(ctx.keymap)
    assert Scope.module_for(:git_status) == MingaGitPorcelain.Keymap.Scope
    assert Enum.member?(Input.surface_handlers(), MingaGitPorcelain.Input.GitStatus)
  end

  defp assert_git_porcelain_contributions_removed(ctx) do
    assert :error = CommandRegistry.lookup(ctx.command_registry, :git_status_toggle)
    assert :not_found = lookup_git_status_keybind(ctx.keymap)
    assert Scope.module_for(:git_status) == nil
    refute Enum.member?(Input.surface_handlers(), MingaGitPorcelain.Input.GitStatus)
  end

  defp lookup_git_status_keybind(keymap) do
    {:ok, keys} = KeyParser.parse("g g")

    keymap
    |> ActiveKeymap.leader_trie()
    |> Bindings.lookup_sequence(keys)
  end

  defp cleanup_git_porcelain_contributions do
    :ok = CommandRegistry.unregister_source(@source)
    :ok = ActiveKeymap.unregister_source(@source)
    :ok = Scope.unregister_source(@source)
    :ok = Input.unregister_source(@source)
  end
end
