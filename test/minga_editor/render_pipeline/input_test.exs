defmodule MingaEditor.RenderPipeline.InputTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState

  setup do
    state = TestHelpers.base_state()
    %{state: state}
  end

  describe "from_editor_state/1" do
    test "extracts workspace fields into workspace map", %{state: state} do
      input = Input.from_editor_state(state)

      assert input.workspace.windows == state.workspace.windows
      assert input.workspace.buffers == state.workspace.buffers
      assert input.workspace.viewport == state.workspace.viewport
      assert input.workspace.editing == state.workspace.editing
      assert input.workspace.highlight == state.workspace.highlight
      assert input.workspace.file_tree == state.workspace.file_tree
      assert input.workspace.agent_ui == state.workspace.agent_ui
      assert input.workspace.completion == state.workspace.completion
      assert input.workspace.document_highlights == state.workspace.document_highlights
      assert input.workspace.search == state.workspace.search
      assert input.workspace.keymap_scope == state.workspace.keymap_scope
    end

    test "extracts top-level state fields", %{state: state} do
      input = Input.from_editor_state(state)

      assert input.port_manager == state.port_manager
      assert input.theme == state.theme
      assert input.capabilities == state.capabilities
      assert input.shell == state.shell
      assert input.shell_state == state.shell_state
      assert input.font_registry == state.font_registry
      assert input.message_store == state.message_store
      assert input.editing_model == state.editing_model
      assert input.backend == state.backend
      assert input.layout == state.layout
      assert input.face_override_registries == state.face_override_registries
    end

    test "excludes GenServer-only fields", %{state: state} do
      input = Input.from_editor_state(state)
      input_fields = input |> Map.from_struct() |> Map.keys() |> MapSet.new()

      # These fields exist on EditorState but must NOT be in Input
      excluded = [
        :render_timer,
        :buffer_monitors,
        :focus_stack,
        :pending_quit,
        :last_test_command,
        :session,
        :git_remote_op,
        :space_leader_pending,
        :space_leader_timer,
        :last_cursor_line,
        :buffer_add_context,
        :stashed_board_state
      ]

      for field <- excluded do
        refute MapSet.member?(input_fields, field),
               "Input should not include EditorState field #{inspect(field)}"
      end
    end

    test "workspace field supports state.workspace.X pattern-matching", %{state: state} do
      input = Input.from_editor_state(state)

      # This is the key compatibility test: pipeline modules do
      # %{workspace: %{editing: editing}} = state
      assert %{workspace: %{editing: editing}} = input
      assert editing == state.workspace.editing
    end
  end

  describe "EditorState.apply_render_output/2" do
    test "writes back mutated windows", %{state: state} do
      input = Input.from_editor_state(state)

      # Simulate a mutation the pipeline would make (new window in map)
      win_id = input.workspace.windows.active
      window = Map.get(input.workspace.windows.map, win_id)

      mutated_cache = %{window.render_cache | last_viewport_top: 42}
      mutated_window = %{window | render_cache: mutated_cache}
      mutated_map = Map.put(input.workspace.windows.map, win_id, mutated_window)
      ws = input.workspace
      mutated_input = %{input | workspace: %{ws | windows: %{ws.windows | map: mutated_map}}}

      result = EditorState.apply_render_output(state, mutated_input)

      assert result.workspace.windows.map[win_id].render_cache.last_viewport_top == 42
    end

    test "preserves fields not in Input", %{state: state} do
      state = %{state | focus_stack: [:test_handler]}
      input = Input.from_editor_state(state)

      result = EditorState.apply_render_output(state, input)

      assert result.focus_stack == [:test_handler]
      assert result.render_timer == state.render_timer
      assert result.buffer_monitors == state.buffer_monitors
    end

    test "writes back layout", %{state: state} do
      input = Input.from_editor_state(state)

      layout = MingaEditor.Layout.compute(state)
      mutated_input = %{input | layout: layout}

      result = EditorState.apply_render_output(state, mutated_input)

      assert result.layout == layout
    end
  end

  describe "sync_active_window_cursor/1" do
    test "syncs cursor from buffer into active window", %{state: state} do
      # Move cursor in the buffer
      buf = state.workspace.buffers.active
      Minga.Buffer.move_to(buf, {1, 0})

      input = Input.from_editor_state(state)
      synced = Input.sync_active_window_cursor(input)

      win_id = synced.workspace.windows.active
      window = Map.get(synced.workspace.windows.map, win_id)
      assert window.cursor == {1, 0}
    end

    test "no-op when no active buffer", %{state: state} do
      ws = state.workspace
      state = %{state | workspace: %{ws | buffers: %{ws.buffers | active: nil}}}
      input = Input.from_editor_state(state)

      assert Input.sync_active_window_cursor(input) == input
    end
  end
end
