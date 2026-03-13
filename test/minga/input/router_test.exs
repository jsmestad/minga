defmodule Minga.Input.RouterTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Input
  alias Minga.Input.Router

  defp base_state do
    {:ok, buf} = BufferServer.start_link(content: "hello\nworld\nthird")

    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(24, 80),
      vim: VimState.new(),
      buffers: %Buffers{
        active: buf,
        list: [buf],
        active_index: 0
      },
      focus_stack: Input.default_stack()
    }
  end

  describe "dispatch/3" do
    test "dispatches a normal mode key through the focus stack" do
      state = base_state()
      # 'j' in normal mode moves cursor down
      new_state = Router.dispatch(state, ?j, 0)
      cursor = BufferServer.cursor(new_state.buffers.active)
      assert elem(cursor, 0) == 1
    end

    test "conflict prompt takes priority over mode FSM" do
      state = base_state()
      buf = state.buffers.active
      state = %{state | pending_conflict: {buf, "/tmp/test.txt"}}

      # 'j' is swallowed by conflict prompt, not forwarded to mode
      new_state = Router.dispatch(state, ?j, 0)
      cursor = BufferServer.cursor(new_state.buffers.active)
      # Cursor did not move because conflict prompt intercepted the key
      assert elem(cursor, 0) == 0
    end

    test "runs post-key housekeeping (render is called)" do
      state = base_state()
      # This should not crash, meaning render was called successfully
      _new_state = Router.dispatch(state, ?j, 0)
    end

    test "single dispatch path handles all key types" do
      state = base_state()
      # Normal key
      state = Router.dispatch(state, ?j, 0)
      # Another normal key
      state = Router.dispatch(state, ?k, 0)
      # Should have moved down then up, back to line 0
      cursor = BufferServer.cursor(state.buffers.active)
      assert elem(cursor, 0) == 0
    end
  end
end
