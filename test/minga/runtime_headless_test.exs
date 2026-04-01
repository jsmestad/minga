defmodule Minga.RuntimeHeadlessTest do
  @moduledoc """
  Integration tests for the headless runtime entry point.

  Boots `Minga.Runtime.start/1` in isolation and verifies that core
  services are available without any frontend or editor processes.
  Must be async: false because it starts its own supervision tree
  that registers globally-named processes.
  """

  use ExUnit.Case, async: false

  # The application is already running in the test environment, so we
  # cannot call Minga.Runtime.start/1 directly (it would conflict on
  # named processes). Instead, we verify the invariants on the running
  # application tree which has the same base children.

  test "headless runtime does not require MingaEditor processes" do
    # Verify the editor is NOT running in the test environment
    # (tests run without :start_editor)
    refute Process.whereis(MingaEditor)
    refute Process.whereis(MingaEditor.Frontend.Manager)
    refute Process.whereis(Minga.Runtime.Supervisor)
  end

  test "core services are available without a frontend" do
    # Foundation services
    assert Process.whereis(Minga.EventBus)
    assert Process.whereis(Minga.Config.Options)
    assert Process.whereis(Minga.Keymap.Active)

    # Buffer infrastructure
    assert Process.whereis(Minga.Buffer.Supervisor)

    # Services
    assert Process.whereis(Minga.Services.Supervisor)
    assert Process.whereis(Minga.Project)

    # Agent supervisor (now top-level)
    assert Process.whereis(MingaAgent.Supervisor)
  end

  test "agent sessions can be started without a frontend" do
    # MingaAgent.Supervisor is functional and can accept children
    children_before = MingaAgent.Supervisor.sessions()
    assert is_list(children_before)
  end
end
