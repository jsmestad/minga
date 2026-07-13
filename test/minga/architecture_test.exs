defmodule Minga.ArchitectureTest do
  @moduledoc """
  Tests for supervision tree structure invariants.

  These tests verify that key supervisors are placed correctly in the
  tree. They inspect the running application's supervision tree, so
  they must not run concurrently with tests that stop/restart supervisors.
  """

  # Serial because this inspects the process-global application supervision tree.
  use ExUnit.Case, async: false

  test "Shell.Registry is a top-level serialized publisher" do
    top_children = Supervisor.which_children(Minga.Supervisor)
    top_ids = Enum.map(top_children, &elem(&1, 0))

    assert MingaEditor.Shell.Registry in top_ids
    assert Process.whereis(MingaEditor.Shell.Registry) != nil
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
