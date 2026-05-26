defmodule MingaEditor.Input.RouterTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.InputRouterMouseProbe
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FocusTree
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Input
  alias MingaEditor.Input.Router

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    Process.put(:sidebar_registry, table)
    :ok
  end

  defp base_state do
    {:ok, buf} = BufferProcess.start_link(content: "hello\nworld\nthird")

    %EditorState{
      port_manager: self(),
      sidebar_registry: Process.get(:sidebar_registry),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        buffers: %Buffers{
          active: buf,
          list: [buf],
          active_index: 0
        }
      },
      focus_stack: Input.default_stack()
    }
  end

  defp probe_tree(deep_ref) do
    FocusTree.link_tree(%FocusNode{
      id: :viewport,
      content_type: :viewport,
      rect: {0, 0, 20, 10},
      children: [
        FocusNode.new(:editor_area, {0, 0, 20, 10},
          children: [
            FocusNode.new(:window, {0, 0, 20, 10},
              handler: InputRouterMouseProbe,
              ref: :window,
              children: [
                FocusNode.new(:buffer_content, {0, 0, 20, 10},
                  handler: InputRouterMouseProbe,
                  ref: deep_ref,
                  scrollable?: true
                )
              ]
            )
          ]
        )
      ]
    })
  end

  defp overlapping_scroll_tree do
    FocusTree.link_tree(%FocusNode{
      id: :viewport,
      content_type: :viewport,
      rect: {0, 0, 20, 10},
      children: [
        FocusNode.new(:buffer_content, {0, 0, 20, 10},
          handler: InputRouterMouseProbe,
          ref: :editor,
          scrollable?: true
        ),
        FocusNode.new(:file_tree, {0, 0, 8, 10},
          handler: InputRouterMouseProbe,
          ref: :tree,
          scrollable?: true
        )
      ]
    })
  end

  defp separator_gap_tree do
    FocusTree.link_tree(%FocusNode{
      id: :viewport,
      content_type: :viewport,
      rect: {0, 0, 20, 10},
      children: [
        FocusNode.new(:buffer_content, {0, 0, 10, 10},
          handler: InputRouterMouseProbe,
          ref: :left
        ),
        FocusNode.new(:buffer_content, {0, 11, 9, 10},
          handler: InputRouterMouseProbe,
          ref: :right
        )
      ]
    })
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
      cursor = BufferProcess.cursor(new_state.workspace.buffers.active)
      assert elem(cursor, 0) == 1
    end

    test "conflict prompt takes priority over mode FSM" do
      alias MingaEditor.State.ModalOverlay
      alias MingaEditor.State.ModalOverlay.Conflict, as: ConflictPayload

      state = base_state()
      buf = state.workspace.buffers.active
      state = ModalOverlay.open(state, :conflict, ConflictPayload.new(buf, "/tmp/test.txt"))

      # 'j' is swallowed by conflict prompt, not forwarded to mode
      new_state = Router.dispatch(state, ?j, 0)
      cursor = BufferProcess.cursor(new_state.workspace.buffers.active)
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
      assert new_state.workspace.editing.mode == :operator_pending

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
      cursor = BufferProcess.cursor(state.workspace.buffers.active)
      assert elem(cursor, 0) == 0
    end
  end

  describe "dispatch_mouse/7" do
    test "calls the deepest hit node handler first" do
      state = %{base_state() | focus_tree: probe_tree(:deep)}

      _state = Router.dispatch_mouse(state, 5, 5, :left, 0, :press, 1)

      assert_receive {:mouse_probe, :buffer_content, :deep}
      refute_receive {:mouse_probe, :window, :window}, 20
    end

    test "bubbles to ancestors when the child passes through" do
      state = %{base_state() | focus_tree: probe_tree({:pass, :child})}

      _state = Router.dispatch_mouse(state, 5, 5, :left, 0, :press, 1)

      assert_receive {:mouse_probe, :buffer_content, {:pass, :child}}
      assert_receive {:mouse_probe, :window, :window}
    end

    test "wheel events start at the deepest scrollable node under the cursor" do
      state = %{base_state() | focus_tree: overlapping_scroll_tree()}

      _state = Router.dispatch_mouse(state, 3, 3, :wheel_down, 0, :press, 1)

      assert_receive {:mouse_probe, :file_tree, :tree}
      refute_receive {:mouse_probe, :buffer_content, :editor}, 20
    end

    test "clicking a separator gap without a handler is a no-op" do
      state = %{base_state() | focus_tree: separator_gap_tree()}

      assert ^state = Router.dispatch_mouse(state, 3, 10, :left, 0, :press, 1)
      refute_receive {:mouse_probe, _type, _ref}, 20
    end
  end

  describe "capture_snapshot/1" do
    test "returns pre-action state for an active buffer" do
      state = base_state()
      snapshot = Router.capture_snapshot(state)

      assert snapshot.old_buffer == state.workspace.buffers.active
      assert snapshot.old_mode == :normal
      assert snapshot.old_cursor == {0, 0}
      assert snapshot.buf_version == BufferProcess.version(state.workspace.buffers.active)
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
      assert state.workspace.editing.mode == :visual

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

  describe "keystroke recording" do
    alias MingaEditor.KeystrokeHistory

    test "dispatch records a keystroke in the history" do
      state = base_state()
      assert KeystrokeHistory.size(state.keystroke_history) == 0

      state = Router.dispatch(state, ?j, 0)

      assert KeystrokeHistory.size(state.keystroke_history) == 1
      [entry] = KeystrokeHistory.entries(state.keystroke_history)
      assert entry.key == {?j, 0}
      assert entry.mode_before == :normal
    end

    test "multiple dispatches accumulate entries" do
      state = base_state()

      state =
        state
        |> Router.dispatch(?j, 0)
        |> Router.dispatch(?k, 0)
        |> Router.dispatch(?l, 0)

      assert KeystrokeHistory.size(state.keystroke_history) == 3
      keys = Enum.map(KeystrokeHistory.entries(state.keystroke_history), & &1.key)
      assert keys == [{?j, 0}, {?k, 0}, {?l, 0}]
    end
  end
end
