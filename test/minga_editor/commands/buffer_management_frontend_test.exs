defmodule MingaEditor.Commands.BufferManagement.FrontendTest do
  use ExUnit.Case, async: true

  alias MingaEditor.BottomPanel
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport
  alias MingaEditor.Session.State, as: SessionState

  # The message-panel commands no longer branch on the frontend. Both the macOS
  # GUI and the Go TUI advertise `semantic_ui` and share the single bottom-panel
  # behaviour, so these tests drive the collapsed dispatch through
  # `BufferManagement.execute/2` for each live capability set.
  @gui %Capabilities{frontend_type: :native_gui, semantic_ui: true}
  @go_tui %Capabilities{frontend_type: :tui, semantic_ui: true}

  defp base_state(caps) do
    %EditorState{
      port_manager: nil,
      capabilities: caps,
      workspace: %SessionState{
        viewport: Viewport.new(40, 120),
        buffers: %Buffers{}
      }
    }
  end

  describe ":view_messages" do
    for {label, caps} <- [{"GUI", @gui}, {"Go TUI", @go_tui}] do
      test "#{label} opens bottom panel on messages tab without stealing focus" do
        state = BufferManagement.execute(base_state(unquote(Macro.escape(caps))), :view_messages)
        assert EditorState.bottom_panel(state).visible == true
        assert EditorState.bottom_panel(state).active_tab == :messages
        assert EditorState.bottom_panel(state).filter == nil
        assert EditorState.bottom_panel(state).focused == false
      end
    end

    test "clears dismissed state" do
      state = MingaEditor.State.set_bottom_panel(base_state(@gui), %BottomPanel{dismissed: true})
      state = BufferManagement.execute(state, :view_messages)
      assert EditorState.bottom_panel(state).dismissed == false
    end
  end

  describe ":view_warnings" do
    for {label, caps} <- [{"GUI", @gui}, {"Go TUI", @go_tui}] do
      test "#{label} opens bottom panel with warnings filter without stealing focus" do
        state = BufferManagement.execute(base_state(unquote(Macro.escape(caps))), :view_warnings)
        assert EditorState.bottom_panel(state).visible == true
        assert EditorState.bottom_panel(state).active_tab == :messages
        assert EditorState.bottom_panel(state).filter == :warnings
        assert EditorState.bottom_panel(state).focused == false
      end
    end
  end
end
