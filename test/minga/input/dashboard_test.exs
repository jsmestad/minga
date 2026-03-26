defmodule Minga.Input.DashboardTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Dashboard
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Input.Dashboard, as: DashInput

  defp state_with_dashboard do
    dash = Dashboard.new_state()

    %EditorState{
      port_manager: self(),
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: nil}
      },
      focus_stack: Minga.Input.default_stack(),
      shell_state: %Minga.Shell.Traditional.State{dashboard: dash}
    }
  end

  # Kitty keyboard protocol arrow key codepoints
  @arrow_up 57_352
  @arrow_down 57_353

  describe "handle_key/3 when dashboard is active" do
    test "j moves cursor down" do
      state = state_with_dashboard()
      assert state.shell_state.dashboard.cursor == 0

      {:handled, new_state} = DashInput.handle_key(state, ?j, 0)
      assert new_state.shell_state.dashboard.cursor == 1
    end

    test "k moves cursor up (wraps)" do
      state = state_with_dashboard()
      assert state.shell_state.dashboard.cursor == 0

      {:handled, new_state} = DashInput.handle_key(state, ?k, 0)

      assert new_state.shell_state.dashboard.cursor ==
               length(state.shell_state.dashboard.items) - 1
    end

    test "arrow down moves cursor down" do
      state = state_with_dashboard()
      assert state.shell_state.dashboard.cursor == 0

      {:handled, new_state} = DashInput.handle_key(state, @arrow_down, 0)
      assert new_state.shell_state.dashboard.cursor == 1
    end

    test "arrow up moves cursor up (wraps)" do
      state = state_with_dashboard()
      assert state.shell_state.dashboard.cursor == 0

      {:handled, new_state} = DashInput.handle_key(state, @arrow_up, 0)

      assert new_state.shell_state.dashboard.cursor ==
               length(state.shell_state.dashboard.items) - 1
    end

    test "space selects the current item and clears dashboard" do
      state = state_with_dashboard()
      # First item is :find_file which opens a picker; the picker open
      # call will fail in this test context but the dashboard should
      # still be cleared. Catch the error and verify the intent.
      result = DashInput.handle_key(state, 32, 0)
      assert {:handled, new_state} = result
      assert new_state.shell_state.dashboard == nil
    end

    test "other keys pass through" do
      state = state_with_dashboard()
      {:passthrough, _} = DashInput.handle_key(state, ?x, 0)
    end
  end

  describe "handle_key/3 when no dashboard" do
    test "passes through when buffers.active is set" do
      alias Minga.Buffer.Server, as: BufferServer
      {:ok, buf} = BufferServer.start_link(content: "hello")

      state = %EditorState{
        port_manager: self(),
        workspace: %Minga.Workspace.State{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{active: buf, list: [buf]}
        },
        focus_stack: Minga.Input.default_stack()
      }

      {:passthrough, _} = DashInput.handle_key(state, ?j, 0)
    end

    test "passes through when dashboard state is nil" do
      state = %EditorState{
        port_manager: self(),
        workspace: %Minga.Workspace.State{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{active: nil}
        },
        focus_stack: Minga.Input.default_stack(),
        shell_state: %Minga.Shell.Traditional.State{dashboard: nil}
      }

      {:passthrough, _} = DashInput.handle_key(state, ?j, 0)
    end
  end
end
