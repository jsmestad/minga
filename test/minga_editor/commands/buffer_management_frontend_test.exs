defmodule MingaEditor.Commands.BufferManagement.FrontendTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Session.State, as: SessionState

  # The message-panel commands no longer branch on the frontend. Both the macOS
  # GUI and the Go TUI advertise `semantic_ui` and share the single bottom-panel
  # behaviour, so these tests drive the collapsed dispatch through
  # `BufferManagement.execute/2` for each live capability set.
  @gui %Capabilities{frontend_type: :native_gui, semantic_ui: true}
  @go_tui %Capabilities{frontend_type: :tui, semantic_ui: true}

  defp base_state(caps) do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil, capabilities: caps},
      workspace: %SessionState{buffers: %Buffers{}}
    }
  end

  describe ":view_messages" do
    for {label, caps} <- [{"GUI", @gui}, {"Go TUI", @go_tui}] do
      test "#{label} opens bottom panel with no filter and without stealing focus" do
        state = BufferManagement.execute(base_state(unquote(Macro.escape(caps))), :view_messages)
        assert state.shell_runtime.state.bottom_panel.visible == true
        assert state.shell_runtime.state.bottom_panel.filter == nil
        assert state.shell_runtime.state.bottom_panel.focused == false
      end
    end
  end

  describe ":view_warnings" do
    for {label, caps} <- [{"GUI", @gui}, {"Go TUI", @go_tui}] do
      test "#{label} opens bottom panel with warnings filter and without stealing focus" do
        state = BufferManagement.execute(base_state(unquote(Macro.escape(caps))), :view_warnings)
        assert state.shell_runtime.state.bottom_panel.visible == true
        assert state.shell_runtime.state.bottom_panel.filter == :warnings
        assert state.shell_runtime.state.bottom_panel.focused == false
      end
    end
  end
end
