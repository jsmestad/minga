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
