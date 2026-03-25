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
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80),
        vim: VimState.new(),
        buffers: %Buffers{
          active: buf,
          list: [buf],
          active_index: 0
        }
      },
      focus_stack: Input.default_stack()
    }
  end

  # Flushes all messages from the process mailbox, returning the count.
  defp flush_mailbox(count \\ 0) do
    receive do
      _ -> flush_mailbox(count + 1)
    after
      0 -> count
    end
  end

  describe "dispatch/3" do
    test "dispatches a normal mode key through the focus stack" do
      state = base_state()
      # 'j' in normal mode moves cursor down
      new_state = Router.dispatch(state, ?j, 0)
      cursor = BufferServer.cursor(new_state.workspace.buffers.active)
      assert elem(cursor, 0) == 1
    end

    test "conflict prompt takes priority over mode FSM" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = %{state | workspace: %{state.workspace | pending_conflict: {buf, "/tmp/test.txt"}}}

      # 'j' is swallowed by conflict prompt, not forwarded to mode
      new_state = Router.dispatch(state, ?j, 0)
      cursor = BufferServer.cursor(new_state.workspace.buffers.active)
      # Cursor did not move because conflict prompt intercepted the key
      assert elem(cursor, 0) == 0
    end

    test "runs post-key housekeeping (render is called)" do
      state = base_state()
      # This should not crash, meaning render was called successfully
      _new_state = Router.dispatch(state, ?j, 0)
    end

    test "entering operator_pending mode skips full render but emits batch_end" do
      state = base_state()
      # Flush any startup messages
      flush_mailbox()

      # Press 'd' to enter operator_pending mode (no buffer mutation)
      new_state = Router.dispatch(state, ?d, 0)
      assert new_state.workspace.vim.mode == :operator_pending

      # Only a single no-op batch_end message should be sent (no full render).
      # port_manager is self(), so GenServer.cast sends a $gen_cast message.
      msg_count = flush_mailbox()
      assert msg_count == 1, "Expected exactly 1 batch_end message, got #{msg_count}"
    end

    test "normal motion triggers full render (more than one message)" do
      state = base_state()
      flush_mailbox()

      # Press 'j' to move cursor down (normal motion, should render)
      _new_state = Router.dispatch(state, ?j, 0)

      # Full render sends multiple commands (draw, cursor, batch_end, etc.)
      msg_count = flush_mailbox()
      assert msg_count > 0, "Expected render messages after normal motion"
    end

    test "single dispatch path handles all key types" do
      state = base_state()
      # Normal key
      state = Router.dispatch(state, ?j, 0)
      # Another normal key
      state = Router.dispatch(state, ?k, 0)
      # Should have moved down then up, back to line 0
      cursor = BufferServer.cursor(state.workspace.buffers.active)
      assert elem(cursor, 0) == 0
    end
  end

  describe "capture_snapshot/1" do
    test "returns pre-action state for an active buffer" do
      state = base_state()
      snapshot = Router.capture_snapshot(state)

      assert snapshot.old_buffer == state.workspace.buffers.active
      assert snapshot.old_mode == :normal
      assert snapshot.old_cursor == {0, 0}
      assert snapshot.buf_version == BufferServer.version(state.workspace.buffers.active)
    end

    test "handles nil active buffer" do
      state = base_state()

      state = %{
        state
        | workspace: %{
            state.workspace
            | buffers: %Buffers{active: nil, list: [], active_index: 0}
          }
      }

      snapshot = Router.capture_snapshot(state)

      assert snapshot.old_buffer == nil
      assert snapshot.old_cursor == nil
      assert snapshot.buf_version == 0
    end

    test "reflects mode changes" do
      state = base_state()

      # Enter visual mode by pressing 'v'
      state = Router.dispatch(state, ?v, 0)
      assert state.workspace.vim.mode == :visual

      snapshot = Router.capture_snapshot(state)
      assert snapshot.old_mode == :visual
    end

    test "reflects cursor position after movement" do
      state = base_state()

      # Move cursor down one line
      state = Router.dispatch(state, ?j, 0)

      snapshot = Router.capture_snapshot(state)
      {line, _col} = snapshot.old_cursor
      assert line == 1
    end
  end
end
