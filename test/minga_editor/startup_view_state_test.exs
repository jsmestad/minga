defmodule MingaEditor.StartupViewStateTest do
  # Mutates the global :cli_startup_flags Application environment while verifying the startup boundary.
  use ExUnit.Case, async: false

  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Startup

  test "defaults to editor view for TUI startup" do
    {scope, ui_state} = Startup.startup_view_state(:tui)

    assert scope == :editor
    assert View.active?(ui_state.view) == false
  end

  test "CLI startup flags select editor, agentic, and native GUI auto modes" do
    assert_startup_scope(:tui, :editor, :editor, false)
    assert_startup_scope(:native_gui, :agentic, :agent, true)
    assert_startup_scope(:native_gui, :auto, :editor, false)
  end

  defp assert_startup_scope(backend, view_mode, expected_scope, expected_active?) do
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, :cli_startup_flags, %{view_mode: view_mode, no_context: false})

    {scope, agentic} = Startup.startup_view_state(backend)

    assert scope == expected_scope
    assert View.active?(agentic.view) == expected_active?
  after
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.delete_env(:minga, :cli_startup_flags)
  end
end
