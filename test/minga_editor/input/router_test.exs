defmodule MingaEditor.Input.RouterTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.InputRouterMouseProbe
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.BottomPanel
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FocusTree
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Render
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Input.Router
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State.Mouse, as: MouseState
  alias MingaEditor.State.Windows

  @async_render_timeout 5_000

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})

    frontend =
      start_supervised!(
        {RecordingFrontend, owner: self()},
        id: {:router_recording_frontend, System.unique_integer([:positive])}
      )

    Process.put(:sidebar_registry, table)
    Process.put(:router_recording_frontend, frontend)
    :ok
  end

  defmodule LegacyMouseProbe do
    @moduledoc false

    @behaviour MingaEditor.Input.Handler

    @impl true
    def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

    @impl true
    def handle_mouse(state, row, col, button, mods, event_type, click_count) do
      send(self(), {:legacy_mouse_probe, row, col, button, mods, event_type, click_count})
      {:handled, state}
    end
  end

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferProcess.start_link(content: "hello\nworld\nthird")

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: Process.get(:router_recording_frontend)},
      extension_surfaces: %MingaEditor.State.ExtensionSurfaces{
        sidebar_registry: Process.get(:sidebar_registry)
      },
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{
          active: buf,
          list: [buf],
          active_index: 0
        }
      },
      interaction:
        MingaEditor.State.Interaction.new(editing_model: Keyword.get(opts, :editing_model, :vim))
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

  defp legacy_probe_tree do
    FocusTree.link_tree(%FocusNode{
      id: :viewport,
      content_type: :viewport,
      rect: {0, 0, 20, 10},
      children: [
        FocusNode.new(:legacy_region, {0, 0, 20, 10}, handler: LegacyMouseProbe)
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

  defp bottom_panel_tree do
    FocusTree.link_tree(%FocusNode{
      id: :viewport,
      content_type: :viewport,
      rect: {0, 0, 20, 10},
      children: [
        FocusNode.new(:buffer_content, {0, 0, 20, 10},
          handler: InputRouterMouseProbe,
          ref: :editor
        ),
        FocusNode.new(:bottom_panel, {7, 0, 20, 3},
          handler: MingaEditor.Input.BottomPanel,
          scrollable?: true,
          focusable?: true
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

  defp install_resize_drag(state) do
    windows = Windows.set_tree(state.workspace.windows, {:leaf, state.workspace.windows.active})

    workspace =
      state.workspace
      |> MingaEditor.Session.State.set_mouse(
        MouseState.start_resize(state.workspace.mouse, :vertical, 10)
      )
      |> MingaEditor.Session.State.set_windows(windows)

    %{state | workspace: workspace}
  end

  describe "dispatch/3" do
    test "dispatches a normal mode key through shell handlers" do
      state = base_state()
      # 'j' in normal mode moves cursor down
      new_state = Router.dispatch(state, ?j, 0)
      cursor = BufferProcess.cursor(new_state.workspace.buffers.active)
      assert elem(cursor, 0) == 1
    end

    test "ordinary keyboard input acknowledges a notice before dispatch" do
      state = base_state() |> NoticeWorkflow.publish("clear me")

      new_state = Router.dispatch(state, ?j, 0)

      assert new_state.shell_runtime.state.notice.message == nil
    end

    test "keyboard acknowledgement cannot erase feedback produced by the dispatched command" do
      state = base_state() |> NoticeWorkflow.publish("old notice")

      new_state = Router.dispatch(state, ?s, MingaEditor.Frontend.Protocol.mod_ctrl())

      assert new_state.shell_runtime.state.notice.message == "No file name — use :w <filename>"
    end

    test "conflict prompt takes priority over mode FSM" do
      alias MingaEditor.Shell.Traditional.ModalWorkflow
      alias MingaEditor.State.ModalOverlay.Conflict, as: ConflictPayload

      state = base_state()
      buf = state.workspace.buffers.active
      state = ModalWorkflow.open(state, {:conflict, ConflictPayload.new(buf, "/tmp/test.txt")})

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

    test "entering operator_pending mode still renders a committed frame" do
      state = base_state()
      flush_mailbox()

      new_state = Router.dispatch(state, ?d, 0)
      assert new_state.workspace.editing.mode == :operator_pending

      msg_count = flush_mailbox()
      assert msg_count > 0, "Expected render messages for operator-pending transition"
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

    test "focused bottom panel handles Vim normal q" do
      state =
        then(base_state(), fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_bottom_panel(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              %BottomPanel{
                visible: true,
                focused: true
              }
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      new_state = Router.dispatch(state, ?q, 0)

      refute new_state.shell_runtime.state.bottom_panel.visible
    end

    test "focused bottom panel handles CUA Escape" do
      state =
        then(base_state(editing_model: :cua), fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_bottom_panel(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              %BottomPanel{
                visible: true,
                focused: true
              }
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      new_state = Router.dispatch(state, 27, 0)

      refute new_state.shell_runtime.state.bottom_panel.visible
    end

    test "focused bottom panel consumes CUA q without closing or editing the buffer" do
      state =
        then(base_state(editing_model: :cua), fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_bottom_panel(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              %BottomPanel{
                visible: true,
                focused: true
              }
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      before_content = BufferProcess.content(state.workspace.buffers.active)
      new_state = Router.dispatch(state, ?q, 0)

      assert new_state.shell_runtime.state.bottom_panel.visible
      assert BufferProcess.content(new_state.workspace.buffers.active) == before_content
    end
  end

  describe "operator-pending frame acknowledgement (#2739)" do
    alias MingaEditor.Renderer.Server, as: RendererServer
    alias MingaEditor.Viewport

    defp async_state(renderer_pid) do
      buf = start_supervised!({BufferProcess, content: "hello\nworld\nthird"})

      %EditorState{
        frontend: %MingaEditor.State.Frontend{
          backend: :tui,
          port_manager: Process.get(:router_recording_frontend),
          terminal_viewport: Viewport.new(24, 80)
        },
        render: %MingaEditor.State.Render{renderer: renderer_pid},
        extension_surfaces: %MingaEditor.State.ExtensionSurfaces{
          sidebar_registry: Process.get(:sidebar_registry)
        },
        workspace: %MingaEditor.Session.State{
          editing: VimState.new(),
          buffers: %Buffers{active: buf, list: [buf], active_index: 0},
          windows: %MingaEditor.State.Windows{
            tree: MingaEditor.WindowTree.new(1),
            map: %{1 => MingaEditor.Window.new(1, buf, 24, 80)},
            active: 1,
            next_id: 2
          }
        },
        interaction: %MingaEditor.State.Interaction{}
      }
    end

    defp acknowledged_probe(parent) do
      fn input ->
        send(parent, {
          :acknowledged_render,
          input.frame_seq,
          input.caches.recovery_generation,
          input.caches.last_acknowledged_frame_seq
        })

        %{
          input
          | caches: %{
              input.caches
              | last_emitted_frame_seq: input.frame_seq,
                last_frame_keyframe?: input.caches.last_acknowledged_frame_seq == 0
            }
        }
      end
    end

    test "operator-pending followed by a normal render uses only the acknowledged renderer base" do
      renderer =
        start_supervised!(
          {RendererServer,
           name: nil, editor_pid: self(), pipeline: acknowledged_probe(self()), require_ack?: true}
        )

      state = async_state(renderer)
      flush_mailbox()

      pending_state = Router.dispatch(state, ?d, 0)
      assert pending_state.workspace.editing.mode == :operator_pending
      assert_receive {:acknowledged_render, first_seq, 1, 0}, @async_render_timeout
      refute_receive {:frontend_commands, _frontend, _commands}, 20

      RendererServer.frame_status(renderer, {:frame_applied, 1, first_seq})
      assert_receive {:render_done, %{frame_seq: ^first_seq}}, @async_render_timeout

      normal_state = Router.dispatch(pending_state, ?w, 0)
      assert normal_state.workspace.editing.mode == :normal
      assert_receive {:acknowledged_render, second_seq, 1, ^first_seq}, @async_render_timeout
      assert second_seq > first_seq
      assert RendererServer.acknowledgement_state(renderer) == {1, first_seq}
    end
  end

  describe "dispatch_mouse/7" do
    test "calls the deepest hit node handler first" do
      state = state_with_focus_tree(probe_tree(:deep))

      _state = Router.dispatch_mouse(state, 5, 5, :left, 0, :press, 1)

      assert_receive {:mouse_probe, :buffer_content, :deep}
      refute_receive {:mouse_probe, :window, :window}, 20
    end

    test "bubbles to ancestors when the child passes through" do
      state = state_with_focus_tree(probe_tree({:pass, :child}))

      _state = Router.dispatch_mouse(state, 5, 5, :left, 0, :press, 1)

      assert_receive {:mouse_probe, :buffer_content, {:pass, :child}}
      assert_receive {:mouse_probe, :window, :window}
    end

    test "falls back to legacy handle_mouse/7 when a node handler has no node-aware callback" do
      state = state_with_focus_tree(legacy_probe_tree())

      assert ^state = Router.dispatch_mouse(state, 4, 6, :left, 0, :press, 1)

      assert_receive {:legacy_mouse_probe, 4, 6, :left, 0, :press, 1}
    end

    test "wheel events start at the deepest scrollable node under the cursor" do
      state = state_with_focus_tree(overlapping_scroll_tree())

      _state = Router.dispatch_mouse(state, 3, 3, :wheel_down, 0, :press, 1)

      assert_receive {:mouse_probe, :file_tree, :tree}
      refute_receive {:mouse_probe, :buffer_content, :editor}, 20
    end

    test "clicking the bottom panel focuses it instead of the underlying editor" do
      state = state_with_focus_tree(bottom_panel_tree())

      state =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_bottom_panel(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              %BottomPanel{
                visible: true
              }
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      new_state = Router.dispatch_mouse(state, 8, 10, :left, 0, :press, 1)

      assert BottomPanel.focused?(new_state.shell_runtime.state.bottom_panel)
      refute_receive {:mouse_probe, :buffer_content, :editor}, 20
    end

    test "clicking a separator gap without a handler is a no-op" do
      state = state_with_focus_tree(separator_gap_tree())

      assert ^state = Router.dispatch_mouse(state, 3, 10, :left, 0, :press, 1)
      refute_receive {:mouse_probe, _type, _ref}, 20
    end

    test "active resize release outside the focus tree bypasses hit routing and clears resize state" do
      state = probe_tree(:deep) |> state_with_focus_tree() |> install_resize_drag()

      new_state = Router.dispatch_mouse(state, 25, 5, :left, 0, :release, 1)

      refute MouseState.resizing?(new_state.workspace.mouse)
      refute_receive {:mouse_probe, _type, _ref}, 20
    end

    test "active resize drag bypasses focus-tree node handlers" do
      state = probe_tree(:deep) |> state_with_focus_tree() |> install_resize_drag()

      new_state = Router.dispatch_mouse(state, 5, 5, :left, 0, :drag, 1)

      assert MouseState.resizing?(new_state.workspace.mouse)
      refute_receive {:mouse_probe, _type, _ref}, 20
    end

    test "handled mouse actions preserve an ordinary notice" do
      state = base_state() |> NoticeWorkflow.publish("keep me")
      render = Render.cache_layout(state.render, state.render.layout, bottom_panel_tree())
      state = %{state | render: render}

      state =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_bottom_panel(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              %BottomPanel{
                visible: true
              }
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      new_state = Router.dispatch_mouse(state, 8, 10, :left, 0, :press, 1)

      assert BottomPanel.focused?(new_state.shell_runtime.state.bottom_panel)
      assert new_state.shell_runtime.state.notice == state.shell_runtime.state.notice
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

    test "handles a dead active buffer pid" do
      state = base_state()
      dead = state.workspace.buffers.active
      ref = Process.monitor(dead)

      :ok = GenServer.stop(dead, :normal)
      assert_receive {:DOWN, ^ref, :process, ^dead, :normal}

      snapshot = Router.capture_snapshot(state)

      assert snapshot.old_buffer == dead
      assert snapshot.buf_version == 0
      assert snapshot.old_cursor == nil
      assert snapshot.old_mode == :normal
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

  defp state_with_focus_tree(focus_tree) do
    state = base_state()
    render = Render.cache_layout(state.render, state.render.layout, focus_tree)
    %{state | render: render}
  end

  describe "route_key/3" do
    alias MingaEditor.KeystrokeHistory

    test "routes a key locally without universal render housekeeping" do
      state = base_state()
      state = %{state | render: Render.connect_renderer(state.render, self())}
      revision = state.render.render_correlation.latest_intent_revision

      routed = Router.route_key(state, ?j, 0)

      assert BufferProcess.cursor(routed.workspace.buffers.active) == {1, 0}
      assert KeystrokeHistory.size(routed.interaction.keystroke_history) == 1
      [entry] = KeystrokeHistory.entries(routed.interaction.keystroke_history)
      assert entry.key == {?j, 0}
      assert routed.render.render_correlation.latest_intent_revision == revision
      refute_receive {:"$gen_cast", {:render, _, _, _}}, 0
    end

    test "preserves keyboard-specific completion handling for CUA insertion" do
      state = base_state(editing_model: :cua)
      BufferProcess.move_to(state.workspace.buffers.active, {0, 1})

      completion =
        Minga.Editing.Completion.new(
          [
            completion_item("print"),
            completion_item("put"),
            completion_item("assert")
          ],
          {0, 1}
        )

      payload = MingaEditor.State.ModalOverlay.Completion.new(1, completion: completion)

      state = MingaEditor.Shell.Traditional.ModalWorkflow.open(state, {:completion, payload})

      routed = Router.route_key(state, ?p, 0)

      assert BufferProcess.content(routed.workspace.buffers.active) == "hpello\nworld\nthird"

      labels =
        routed
        |> MingaEditor.Shell.Traditional.ModalWorkflow.completion()
        |> Map.fetch!(:filtered)
        |> Enum.map(& &1.label)

      assert labels == ["print", "put"]
    end
  end

  describe "keystroke recording" do
    alias MingaEditor.KeystrokeHistory

    test "dispatch records a keystroke in the history" do
      state = base_state()
      assert KeystrokeHistory.size(state.interaction.keystroke_history) == 0

      state = Router.dispatch(state, ?j, 0)

      assert KeystrokeHistory.size(state.interaction.keystroke_history) == 1
      [entry] = KeystrokeHistory.entries(state.interaction.keystroke_history)
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

      assert KeystrokeHistory.size(state.interaction.keystroke_history) == 3
      keys = Enum.map(KeystrokeHistory.entries(state.interaction.keystroke_history), & &1.key)
      assert keys == [{?j, 0}, {?k, 0}, {?l, 0}]
    end
  end

  defp completion_item(label) do
    %{
      label: label,
      insert_text: label,
      filter_text: label,
      kind: :function,
      detail: "",
      documentation: "",
      sort_text: label,
      text_edit: nil,
      raw: nil
    }
  end
end
