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
    test "extracts all workspace fields", %{state: state} do
      input = Input.from_editor_state(state)

      assert input.windows == state.workspace.windows
      assert input.buffers == state.workspace.buffers
      assert input.viewport == state.workspace.viewport
      assert input.editing == state.workspace.editing
      assert input.highlight == state.workspace.highlight
      assert input.file_tree == state.workspace.file_tree
      assert input.agent_ui == state.workspace.agent_ui
      assert input.completion == state.workspace.completion
      assert input.document_highlights == state.workspace.document_highlights
      assert input.search == state.workspace.search
      assert input.keymap_scope == state.workspace.keymap_scope
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
        :lsp,
        :parser_status,
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
  end

  describe "EditorState.apply_render_output/2" do
    test "writes back mutated windows", %{state: state} do
      input = Input.from_editor_state(state)

      # Simulate a mutation the pipeline would make (new window in map)
      win_id = input.windows.active
      window = Map.get(input.windows.map, win_id)

      mutated_cache = %{window.render_cache | last_viewport_top: 42}
      mutated_window = %{window | render_cache: mutated_cache}
      mutated_map = Map.put(input.windows.map, win_id, mutated_window)
      mutated_input = %{input | windows: %{input.windows | map: mutated_map}}

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

      # Simulate layout computation
      layout = MingaEditor.Layout.compute(state)
      mutated_input = %{input | layout: layout}

      result = EditorState.apply_render_output(state, mutated_input)

      assert result.layout == layout
    end
  end

  describe "workspace/1" do
    test "returns workspace-shaped map with all fields", %{state: state} do
      input = Input.from_editor_state(state)
      ws = Input.workspace(input)

      assert ws.windows == input.windows
      assert ws.buffers == input.buffers
      assert ws.viewport == input.viewport
      assert ws.editing == input.editing
      assert ws.highlight == input.highlight
      assert ws.search == input.search
      assert ws.keymap_scope == input.keymap_scope
    end
  end
end
