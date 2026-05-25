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
      assert input.workspace.file_tree == EditorState.file_tree_state(state)
      assert input.workspace.agent_ui == state.workspace.agent_ui
      assert input.workspace.document_highlights == state.workspace.document_highlights
      assert input.workspace.search == state.workspace.search
      assert input.workspace.keymap_scope == state.workspace.keymap_scope
    end

    test "extracts top-level state fields", %{state: state} do
      input = Input.from_editor_state(state)

      assert input.port_manager == state.port_manager
      assert input.theme == state.theme
      assert input.capabilities == state.capabilities
      assert input.shell_id == state.shell_id
      assert input.shell == state.shell
      assert input.shell_state == state.shell_state
      assert input.font_registry == MingaEditor.UI.FontRegistry.new()
      assert input.message_store == state.message_store
      assert input.editing_model == state.editing_model
      assert input.backend == state.backend
      assert input.layout == state.layout
      assert input.face_override_registries == state.face_override_registries
    end

    test "excludes GenServer-only fields", %{state: state} do
      input = Input.from_editor_state(state)
      input_fields = input |> Map.from_struct() |> Map.keys() |> MapSet.new()

      # These GenServer-only or Editor-owned fields must NOT be in Input
      excluded = [
        :render_timer,
        :buffer_monitors,
        :focus_stack,
        :pending_quit,
        :last_test_command,
        :session,
        :git_remote_op,
        :last_cursor_line,
        :buffer_add_context,
        :shell_state_stash
      ]

      for field <- excluded do
        refute MapSet.member?(input_fields, field),
               "Input should not include EditorState field #{inspect(field)}"
      end
    end

    test "editor state no longer owns the font registry", %{state: state} do
      refute Map.has_key?(Map.from_struct(state), :font_registry)
    end

    test "workspace field supports state.workspace.X pattern-matching", %{state: state} do
      input = Input.from_editor_state(state)

      # This is the key compatibility test: pipeline modules do
      # %{workspace: %{editing: editing}} = state
      assert %{workspace: %{editing: editing}} = input
      assert editing == state.workspace.editing
    end

    test "with_font_registry/2 attaches renderer-owned registry", %{state: state} do
      input = Input.from_editor_state(state)

      {_id, registry, true} =
        MingaEditor.UI.FontRegistry.get_or_register(input.font_registry, "Fira Code")

      assert Input.with_font_registry(input, registry).font_registry == registry
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

  describe "EditorState.apply_renderer_writeback/2" do
    test "merges renderer-owned fields without overwriting newer editor-owned state", %{
      state: state
    } do
      input = Input.from_editor_state(state)
      win_id = state.workspace.windows.active
      live_window = state.workspace.windows.map[win_id]

      live_window = %{
        live_window
        | cursor: {2, 0},
          viewport: %{live_window.viewport | top: 9}
      }

      state =
        put_in(state.workspace.windows.map[win_id], live_window)
        |> put_in([Access.key(:shell_state), Access.key(:status_msg)], "new status")

      rendered_window = %{
        live_window
        | cursor: {0, 0},
          viewport: %{live_window.viewport | top: 1},
          render_cache: %{live_window.render_cache | last_viewport_top: 42}
      }

      rendered_windows = %{
        state.workspace.windows
        | map: %{win_id => rendered_window},
          active: 999
      }

      rendered_shell_state = %{
        state.shell_state
        | status_msg: "old snapshot",
          modeline_click_regions: [{:modeline, 1}],
          tab_bar_click_regions: [{:tab, 2}]
      }

      writeback = %{
        caches: input.caches,
        layout: :rendered_layout,
        windows: rendered_windows,
        shell_id: :traditional,
        shell_state: rendered_shell_state
      }

      result = EditorState.apply_renderer_writeback(state, writeback)
      result_window = result.workspace.windows.map[win_id]

      assert result.layout == :rendered_layout
      assert result_window.render_cache.last_viewport_top == 42
      assert result_window.cursor == {2, 0}
      assert result_window.viewport.top == 9
      assert result.workspace.windows.active == win_id
      assert result.shell_state.status_msg == "new status"
      assert result.shell_state.modeline_click_regions == [{:modeline, 1}]
      assert result.shell_state.tab_bar_click_regions == [{:tab, 2}]
    end

    test "does not merge stale shell click regions after shell changes", %{state: state} do
      input = Input.from_editor_state(state)

      writeback = %{
        caches: input.caches,
        layout: :rendered_layout,
        windows: state.workspace.windows,
        shell_id: :traditional,
        shell_state: %{state.shell_state | modeline_click_regions: [{:old, 1}]}
      }

      state = EditorState.switch_shell(state, :board)
      result = EditorState.apply_renderer_writeback(state, writeback)

      assert result.layout == :rendered_layout
      assert result.shell_id == :board
      assert result.shell_state.modeline_click_regions == []
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
