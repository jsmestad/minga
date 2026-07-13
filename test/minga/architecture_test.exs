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
      Minga.Supervisor
      |> Supervisor.which_children()
      |> Map.new(fn {id, pid, _type, _modules} -> {id, pid} end)

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

  test "MingaAgent.Supervisor is a top-level peer, not nested under Services" do
    top_children = Supervisor.which_children(Minga.Supervisor)
    top_ids = Enum.map(top_children, &elem(&1, 0))
    assert MingaAgent.Supervisor in top_ids

    services_children = Supervisor.which_children(Minga.Services.Supervisor)
    services_ids = Enum.map(services_children, &elem(&1, 0))
    refute MingaAgent.Supervisor in services_ids
  end
end
