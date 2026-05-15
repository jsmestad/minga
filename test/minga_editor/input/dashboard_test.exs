defmodule MingaEditor.Input.DashboardTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Dashboard
  alias MingaEditor.Input.Dashboard, as: DashInput
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Dashboard, as: DashboardPayload
  alias MingaEditor.Viewport

  defp state_with_dashboard do
    base = %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: nil}
      },
      focus_stack: MingaEditor.Input.default_stack()
    }

    ModalOverlay.open(base, :dashboard, DashboardPayload.new(Dashboard.new_state()))
  end

  defp dashboard_payload(state) do
    case state.shell_state.modal do
      {:dashboard, payload} -> payload
      _ -> nil
    end
  end

  # Kitty keyboard protocol arrow key codepoints
  @arrow_up 57_352
  @arrow_down 57_353

  describe "handle_key/3 when dashboard is active" do
    test "j moves cursor down" do
      state = state_with_dashboard()
      assert dashboard_payload(state).state.cursor == 0

      {:handled, new_state} = DashInput.handle_key(state, ?j, 0)
      assert dashboard_payload(new_state).state.cursor == 1
    end

    test "k moves cursor up (wraps)" do
      state = state_with_dashboard()
      assert dashboard_payload(state).state.cursor == 0

      {:handled, new_state} = DashInput.handle_key(state, ?k, 0)
      payload = dashboard_payload(state)

      assert dashboard_payload(new_state).state.cursor == length(payload.state.items) - 1
    end

    test "arrow down moves cursor down" do
      state = state_with_dashboard()
      assert dashboard_payload(state).state.cursor == 0

      {:handled, new_state} = DashInput.handle_key(state, @arrow_down, 0)
      assert dashboard_payload(new_state).state.cursor == 1
    end

    test "arrow up moves cursor up (wraps)" do
      state = state_with_dashboard()
      assert dashboard_payload(state).state.cursor == 0

      {:handled, new_state} = DashInput.handle_key(state, @arrow_up, 0)
      payload = dashboard_payload(state)

      assert dashboard_payload(new_state).state.cursor == length(payload.state.items) - 1
    end

    test "space selects the current item and clears dashboard" do
      state = state_with_dashboard()
      # First item is :find_file which opens a picker; the picker open
      # call may fail in this test context but the dashboard should
      # still be cleared. Catch the error and verify the intent.
      result = DashInput.handle_key(state, 32, 0)
      assert {:handled, new_state} = result
      refute ModalOverlay.match(new_state.shell_state.modal, :dashboard)
    end

    test "other keys pass through" do
      state = state_with_dashboard()
      {:passthrough, _} = DashInput.handle_key(state, ?x, 0)
    end
  end

  describe "handle_key/3 when no dashboard" do
    test "passes through when buffers.active is set and modal is :none" do
      alias Minga.Buffer.Process, as: BufferProcess
      {:ok, buf} = BufferProcess.start_link(content: "hello")

      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Workspace.State{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{active: buf, list: [buf]}
        },
        focus_stack: MingaEditor.Input.default_stack()
      }

      {:passthrough, _} = DashInput.handle_key(state, ?j, 0)
    end

    test "passes through when modal is :none" do
      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Workspace.State{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{active: nil}
        },
        focus_stack: MingaEditor.Input.default_stack()
      }

      {:passthrough, _} = DashInput.handle_key(state, ?j, 0)
    end
  end
end
