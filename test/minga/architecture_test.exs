defmodule Minga.ArchitectureTest do
  @moduledoc """
  Tests for supervision tree structure invariants.

  These tests verify that key supervisors are placed correctly in the
  tree. They inspect the running application's supervision tree, so
  they must not run concurrently with tests that stop/restart supervisors.
  """

  # Serial because this inspects the process-global application supervision tree.
  use ExUnit.Case, async: false

  @supervision_timeout 5_000

  test "Shell.Registry is a top-level serialized publisher" do
    top_children = Supervisor.which_children(Minga.Supervisor)
    top_ids = Enum.map(top_children, &elem(&1, 0))

    assert MingaEditor.Shell.Registry in top_ids
    assert Process.whereis(MingaEditor.Shell.Registry) != nil
  end

  test "Shell.Registry crash reseeds Traditional and restarts downstream supervisors" do
    :ok = MingaEditor.Shell.Registry.reset_for_test()
    assert MingaEditor.Shell.Registry.resolve(:traditional) == nil

    registry = Process.whereis(MingaEditor.Shell.Registry)
    foundation = Process.whereis(Minga.Foundation.Supervisor)
    services = Process.whereis(Minga.Services.Supervisor)
    registry_ref = Process.monitor(registry)
    foundation_ref = Process.monitor(foundation)
    services_ref = Process.monitor(services)

    Process.exit(registry, :kill)

    assert_receive {:DOWN, ^registry_ref, :process, ^registry, :killed}, @supervision_timeout

    assert_receive {:DOWN, ^foundation_ref, :process, ^foundation, _foundation_reason},
                   @supervision_timeout

    assert_receive {:DOWN, ^services_ref, :process, ^services, _services_reason},
                   @supervision_timeout

    children =
      await_restarted_children([
        MingaEditor.Shell.Registry,
        Minga.Foundation.Supervisor,
        Minga.Services.Supervisor
      ])

    new_registry = children[MingaEditor.Shell.Registry]
    new_foundation = children[Minga.Foundation.Supervisor]
    new_services = children[Minga.Services.Supervisor]

    assert is_pid(new_registry)
    assert is_pid(new_foundation)
    assert is_pid(new_services)
    refute new_registry == registry
    refute new_foundation == foundation
    refute new_services == services

    assert %MingaEditor.Shell.Entry{
             id: :traditional,
             source: :builtin,
             module: MingaEditor.Shell.Traditional,
             generation: generation
           } = MingaEditor.Shell.Registry.default()

    assert generation > 0
  end

  test "a crashed Language.Registry comes back with the bundled language and recipe catalogs" do
    assert %Minga.Language{name: :elixir} = Minga.Language.Registry.get(:elixir)
    assert %Minga.Tool.Recipe{name: :expert} = Minga.Tool.Recipe.Registry.get(:expert)

    # Killing the registry also replaces Minga.Events, which drops subscriptions held by processes
    # outside Foundation. Restart Foundation and everything after it so later tests see a coherent tree.
    on_exit(&restart_foundation_and_dependents/0)

    registry = Process.whereis(Minga.Language.Registry)
    registry_ref = Process.monitor(registry)
    Process.exit(registry, :kill)
    assert_receive {:DOWN, ^registry_ref, :process, ^registry, :killed}, @supervision_timeout

    # The supervisor restarts the registry and every later sibling while handling one exit, so
    # a new registry pid in `which_children/1` means the bundled pack loaders have also run.
    await_replaced_child(Minga.Foundation.Supervisor, Minga.Language.Registry, registry)

    assert %Minga.Language{name: :elixir} = Minga.Language.Registry.get(:elixir)
    assert Minga.Language.Registry.for_extension("ex").name == :elixir
    assert %Minga.Tool.Recipe{name: :expert} = Minga.Tool.Recipe.Registry.get(:expert)
  end

  test "extension lifecycle infrastructure is direct under Services in dependency order" do
    children = Supervisor.which_children(Minga.Services.Supervisor)
    ids = children |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    expected = [
      Minga.Extension.Registry,
      Minga.Extension.ArtifactGenerationState,
      Minga.Extension.ArtifactAdmission,
      Minga.Extension.CodeLease,
      Minga.Extension.CallbackRegistry,
      Minga.Extension.InstanceRegistry,
      Minga.Extension.RootSupervisor,
      Minga.Config.Loader
    ]

    assert Enum.all?(expected, &(&1 in ids))
    positions = Enum.map(expected, &Enum.find_index(ids, fn id -> id == &1 end))
    assert positions == Enum.sort(positions)
    refute Minga.Extension.Supervisor in ids
  end

  test "MingaAgent.Supervisor is a top-level peer, not nested under Services" do
    top_children = Supervisor.which_children(Minga.Supervisor)
    top_ids = Enum.map(top_children, &elem(&1, 0))
    assert MingaAgent.Supervisor in top_ids

    services_children = Supervisor.which_children(Minga.Services.Supervisor)
    services_ids = Enum.map(services_children, &elem(&1, 0))
    refute MingaAgent.Supervisor in services_ids
  end

  # Restarts Foundation and every later top-level child through an orderly rest_for_one shutdown.
  # Killing Shell.Registry, the first top-level child, is the path the test above already proves.
  @spec restart_foundation_and_dependents() :: :ok
  defp restart_foundation_and_dependents do
    shell_registry = Process.whereis(MingaEditor.Shell.Registry)
    foundation = Process.whereis(Minga.Foundation.Supervisor)
    foundation_ref = Process.monitor(foundation)

    Process.exit(shell_registry, :kill)

    assert_receive {:DOWN, ^foundation_ref, :process, ^foundation, _reason}, @supervision_timeout

    await_restarted_children([
      MingaEditor.Shell.Registry,
      Minga.Foundation.Supervisor,
      Minga.Services.Supervisor
    ])

    :ok
  end

  @spec await_replaced_child(Supervisor.supervisor(), term(), pid(), non_neg_integer()) :: pid()
  defp await_replaced_child(supervisor, id, old_pid, attempts \\ 500)

  defp await_replaced_child(supervisor, id, old_pid, attempts) when attempts > 0 do
    case List.keyfind(Supervisor.which_children(supervisor), id, 0) do
      {^id, pid, _type, _modules} when is_pid(pid) and pid != old_pid ->
        pid

      _not_restarted ->
        receive do
        after
          10 -> await_replaced_child(supervisor, id, old_pid, attempts - 1)
        end
    end
  end

  defp await_replaced_child(_supervisor, id, _old_pid, 0) do
    flunk("supervision child did not restart: #{inspect(id)}")
  end

  @spec await_restarted_children([term()], non_neg_integer()) :: %{term() => pid()}
  defp await_restarted_children(ids, attempts \\ 500)

  defp await_restarted_children(ids, attempts) when attempts > 0 do
    case Process.whereis(Minga.Supervisor) do
      supervisor when is_pid(supervisor) ->
        children =
          supervisor
          |> Supervisor.which_children()
          |> Map.new(fn {id, pid, _type, _modules} -> {id, pid} end)

        if Enum.all?(ids, &is_pid(children[&1])) do
          children
        else
          await_restarted_children_after(ids, attempts)
        end

      nil ->
        await_restarted_children_after(ids, attempts)
    end
  end

  defp await_restarted_children(ids, 0) do
    flunk("supervision children did not restart: #{inspect(ids)}")
  end

  @spec await_restarted_children_after([term()], pos_integer()) :: %{term() => pid()}
  defp await_restarted_children_after(ids, attempts) do
    receive do
    after
      10 -> await_restarted_children(ids, attempts - 1)
    end
  end
end
