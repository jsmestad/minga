defmodule MingaEditor.Session.StateTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Session.State`.

  Uses `RenderPipeline.TestHelpers.base_state/1` to construct state
  without starting a GenServer.
  """

  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Language.Symbol
  alias MingaEditor.VimState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.Session.State, as: SessionState

  import MingaEditor.RenderPipeline.TestHelpers

  describe "activate_buffer/2" do
    test "syncs buffer content when window shows a buffer" do
      state = base_state()
      ws = state.workspace
      win_id = ws.windows.active
      original_buf = ws.buffers.active

      {:ok, new_buf} = Minga.Buffer.Process.start_link(content: "new content")

      # Update buffers.active to the new buffer, but leave the window pointing at the old one
      ws = %{ws | buffers: %{ws.buffers | active: new_buf}}

      # Confirm the window still points at the old buffer
      window = Map.get(ws.windows.map, win_id)
      assert Content.buffer_pid(window.content) == original_buf
      assert window.content == {:buffer, original_buf}

      # sync should update the window to point at the new buffer
      ws = SessionState.activate_buffer(ws, ws.buffers)

      updated_window = Map.get(ws.windows.map, win_id)
      assert Content.buffer_pid(updated_window.content) == new_buf
      assert updated_window.content == {:buffer, new_buf}
    end

    test "preserves agent_chat content when syncing" do
      state = base_state()
      ws = state.workspace
      win_id = ws.windows.active

      window = Map.get(ws.windows.map, win_id)
      agent_window = %{window | content: Content.agent_chat()}
      ws = %{ws | windows: %{ws.windows | map: Map.put(ws.windows.map, win_id, agent_window)}}

      # Change the active buffer to something different
      {:ok, new_buf} = Minga.Buffer.Process.start_link(content: "new content")
      ws = %{ws | buffers: %{ws.buffers | active: new_buf}}

      # sync should NOT touch the agent_chat window
      ws = SessionState.activate_buffer(ws, ws.buffers)

      result_window = Map.get(ws.windows.map, win_id)
      assert result_window.content == {:agent_chat, :semantic}
      assert Content.buffer_pid(result_window.content) == nil
    end

    test "clears document symbols when the active window switches buffers" do
      state = base_state(content: "defmodule First do\nend\n")
      win_id = state.workspace.windows.active
      {:ok, new_buf} = BufferProcess.start_link(content: "plain text")
      symbols = [%Symbol{kind: :module, name: "First", range: {0, 0, 1, 3}}]

      workspace =
        state.workspace
        |> SessionState.replace_window(
          win_id,
          Window.set_document_symbols(Map.fetch!(state.workspace.windows.map, win_id), symbols)
        )
        |> then(fn ws ->
          %{
            ws
            | buffers: %{
                ws.buffers
                | active: new_buf,
                  list: [ws.buffers.active, new_buf],
                  active_index: 1
              }
          }
        end)

      synced = SessionState.activate_buffer(workspace, workspace.buffers)
      window = Map.fetch!(synced.windows.map, win_id)

      assert window.document_symbols == []
    end

    test "preserves window observations when the requested buffer is already active" do
      state = base_state(content: "defmodule Same do\nend\n")
      window_id = state.workspace.windows.active
      symbols = [%Symbol{kind: :module, name: "Same", range: {0, 0, 1, 3}}]

      workspace =
        SessionState.replace_window(
          state.workspace,
          window_id,
          Window.set_document_symbols(Map.fetch!(state.workspace.windows.map, window_id), symbols)
        )

      activated = SessionState.activate_buffer(workspace, workspace.buffers)
      assert Map.fetch!(activated.windows.map, window_id).document_symbols == symbols
    end

    test "leaves the launchpad with editor scope and clears stale hover observations" do
      workspace = SessionState.enter_empty_state(base_state().workspace)
      {:ok, buffer} = BufferProcess.start_link(content: "opened")
      buffers = Buffers.add(workspace.buffers, buffer)

      workspace =
        workspace
        |> SessionState.set_keymap_scope(:agent)
        |> SessionState.set_cmd_hover_link({{0, 0}, {0, 4}})
        |> SessionState.set_cmd_hover_cell({3, 8})

      activated = SessionState.activate_buffer(workspace, buffers)
      window = Map.fetch!(activated.windows.map, activated.windows.active)

      assert activated.buffers.active == buffer
      assert activated.keymap_scope == :editor
      assert activated.launchpad == nil
      assert activated.hover_observation.link == nil
      assert activated.hover_observation.cell == nil
      assert window.content == {:buffer, buffer}
    end
  end

  describe "focus_window/3" do
    test "atomically focuses split buffer and agent windows from process observations" do
      workspace = base_state().workspace
      first_buffer = workspace.buffers.active
      {:ok, second_buffer} = BufferProcess.start_link(content: "second")
      buffers = workspace.buffers |> Buffers.add(second_buffer) |> Buffers.switch_to(0)

      windows =
        workspace.windows
        |> Windows.add_window(Window.new(2, second_buffer, 24, 80, {1, 2}))
        |> Windows.add_window(Window.new_agent_chat(3, 24, 80))

      workspace =
        workspace
        |> SessionState.activate_buffer(buffers)
        |> SessionState.set_windows(windows)
        |> SessionState.set_keymap_scope(:file_tree)
        |> SessionState.set_cmd_hover_link({{0, 0}, {0, 4}})
        |> SessionState.set_cmd_hover_cell({3, 8})

      focused = SessionState.focus_window(workspace, 2, {2, 3})

      assert focused.windows.active == 2
      assert Map.fetch!(focused.windows.map, 1).cursor == {2, 3}
      assert focused.buffers.active == second_buffer
      assert focused.buffers.active_index == 1
      assert focused.keymap_scope == :file_tree
      assert focused.hover_observation.link == nil
      assert focused.hover_observation.cell == nil
      assert focused.launchpad == nil

      agent_focused = SessionState.focus_window(focused, 3, {1, 2})
      assert agent_focused.windows.active == 3
      assert agent_focused.buffers.active == nil
      assert agent_focused.keymap_scope == :agent
      assert SessionState.focus_window(agent_focused, 99, nil) == agent_focused
      assert first_buffer in agent_focused.buffers.list
    end
  end

  describe "restore_tab_context/2" do
    test "restores flat workspace fields from a tab context" do
      ws = base_state().workspace
      replacement = %{ws.buffers | active: nil, list: [], active_index: 0}

      restored = SessionState.restore_tab_context(ws, %{buffers: replacement})

      assert restored.buffers == replacement
      assert restored.windows == ws.windows
    end

    test "ignores fields that are not part of the workspace" do
      ws = base_state().workspace

      restored = SessionState.restore_tab_context(ws, %{unknown_field: :ignored})

      assert restored == ws
    end
  end

  describe "to_tab_context/1" do
    test "returns a typed context of workspace fields" do
      ws = base_state().workspace
      ctx = SessionState.to_tab_context(ws)

      assert %Context{} = ctx
      assert ctx.buffers == ws.buffers
      assert ctx.windows == ws.windows
      refute Map.has_key?(ctx, :viewport)
      snapshot_fields = SessionState.field_names() -- [:agent_ui]
      assert Enum.sort(snapshot_fields) == Enum.sort(ctx.present_fields)
    end

    test "normalises an in-flight CommandState back to %Mode.State{} when mode is :normal" do
      # Simulates the moment after Command.handle_key/2 returns
      # `{:execute_then_transition, [...], :normal, %CommandState{input: ""}}`
      # and the dispatch wrote that pair into workspace.editing before the
      # ex-command ran (the same moment :e <path> would snapshot).
      ws = base_state().workspace
      mismatched = %VimState{mode: :normal, mode_state: %Mode.CommandState{input: ""}}
      ws = %{ws | editing: mismatched}

      ctx = SessionState.to_tab_context(ws)

      assert ctx.editing.mode == :normal
      assert match?(%Mode.State{}, ctx.editing.mode_state)
    end

    test "passes through editing when mode_state already matches mode" do
      ws = base_state().workspace
      visual_state = %Mode.VisualState{visual_type: :char, visual_anchor: {3, 0}}
      vim = %VimState{mode: :visual, mode_state: visual_state}
      ws = %{ws | editing: vim}

      ctx = SessionState.to_tab_context(ws)

      # Visual is a context-required mode and the snapshot already had a
      # properly-typed VisualState — the visual_anchor must be preserved
      # so the context can be restored verbatim.
      assert ctx.editing.mode == :visual
      assert ctx.editing.mode_state == visual_state
    end
  end
end
