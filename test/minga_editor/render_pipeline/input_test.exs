defmodule MingaEditor.RenderPipeline.InputTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.RenderPipeline.WindowIntent
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Runtime
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.UI.Panel.MessageStore

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
      assert input.highlighting == state.highlighting
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
      assert input.shell_id == Runtime.id(state.shell_runtime)
      assert input.shell == Runtime.module(state.shell_runtime)
      assert input.shell_identity == Runtime.identity(state.shell_runtime)
      assert input.shell_state == Runtime.state(state.shell_runtime)
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
        :shell_runtime
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

  describe "EditorState.reset_frontend_render_state/1" do
    test "resets frontend caches and message send cursor", %{state: state} do
      message_store =
        state.message_store
        |> MessageStore.append("first", :info, :editor)
        |> MessageStore.mark_sent(1)

      state = %{state | message_store: message_store}

      result = EditorState.reset_frontend_render_state(state)

      assert result.message_store.last_sent_id == 0
      assert result.message_store.stream_instance == message_store.stream_instance
      assert Enum.map(result.message_store.entries, & &1.text) == ["first"]
    end
  end

  describe "cache-free render intent" do
    test "contains only semantic window carriers", %{state: state} do
      intent = Intent.from_editor_state(state, 7)

      assert intent.revision == 7
      assert intent.frame.highlighting == state.highlighting
      assert Enum.all?(intent.windows, fn {_id, window} -> match?(%WindowIntent{}, window) end)

      refute Enum.any?(intent.windows, fn {_id, window} ->
               Map.has_key?(Map.from_struct(window), :render_cache)
             end)

      refute Map.has_key?(intent.frame, :caches)
      refute Map.has_key?(intent.frame, :font_registry)
    end
  end

  describe "EditorState.apply_render_output/2" do
    test "writes back bounded editor window observations", %{state: state} do
      input = Input.from_editor_state(state)
      win_id = input.workspace.windows.active
      window = Map.fetch!(input.workspace.windows.map, win_id)

      mutated_cache = %{window.render_cache | viewport_top: 42}
      mutated_window = %{window | render_cache: mutated_cache}
      mutated_map = Map.put(input.workspace.windows.map, win_id, mutated_window)
      ws = input.workspace
      mutated_input = %{input | workspace: %{ws | windows: %{ws.windows | map: mutated_map}}}

      result = EditorState.apply_render_output(state, mutated_input)

      assert result.workspace.windows.map[win_id].render_cache.viewport_top == 42
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

    test "does not write renderer-owned message cursor back to Editor", %{state: state} do
      input = Input.from_editor_state(state)

      message_store =
        state.message_store
        |> MessageStore.append("first", :info, :editor)
        |> MessageStore.append("second", :info, :editor)
        |> MessageStore.mark_sent(2)

      result = EditorState.apply_render_output(state, %{input | message_store: message_store})

      assert result.message_store == state.message_store
    end
  end

  describe "EditorState.apply_renderer_writeback/2" do
    test "applies only editor-owned receipt fields and Editor has no renderer caches",
         %{state: state} do
      input = Input.from_editor_state(state)
      windows = state.workspace.windows

      receipt =
        receipt(input, 10, false,
          layout: :rendered_layout,
          modeline_click_regions: [{:modeline, 1}],
          tab_bar_click_regions: [{:tab, 2}]
        )

      result = EditorState.apply_renderer_writeback(state, receipt)

      assert result.layout == :rendered_layout
      assert result.workspace.windows == windows
      refute Map.has_key?(Map.from_struct(result), :caches)
      assert Runtime.state(result.shell_runtime).modeline_click_regions == [{:modeline, 1}]
      assert Runtime.state(result.shell_runtime).tab_bar_click_regions == [{:tab, 2}]
    end

    test "fresh receipt commits renderer-computed viewport observations", %{state: state} do
      input = Input.from_editor_state(state)
      id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, id)
      viewport = MingaEditor.Viewport.put_top(window.viewport, 12)

      render_window =
        window
        |> WindowIntent.from_window()
        |> WindowIntent.materialize(%MingaEditor.Renderer.WindowCache{
          last_buf_version: window.render_cache.buffer_version
        })
        |> MingaEditor.Renderer.RenderWindow.set_viewport(viewport)

      windows = MingaEditor.State.Windows.set_map(input.workspace.windows, %{id => render_window})
      output = %{input | workspace: %{input.workspace | windows: windows}}
      receipt = MingaEditor.Renderer.RenderReceipt.from_output(output, 10, 0, 0)

      assert %MingaEditor.Renderer.WindowObservation{viewport: ^viewport} =
               receipt.window_observations[id]

      result = EditorState.apply_renderer_writeback(state, receipt)
      observed = Map.fetch!(result.workspace.windows.map, id)

      assert observed.viewport.top == 12
      assert observed.render_cache.viewport_top == 12
    end

    test "stale receipt cannot overwrite newer editor-owned transitions", %{state: state} do
      input = Input.from_editor_state(state)
      newer = receipt(input, 20, false, layout: :newer)
      older = receipt(input, 19, false, layout: :older)

      result =
        state
        |> EditorState.apply_renderer_writeback(newer)
        |> EditorState.apply_renderer_writeback(older)

      assert result.layout == :newer
      assert result.last_render_receipt_seq == 20
    end

    test "pending acknowledgement is stale after a newer resize/focus/shell intent", %{
      state: state
    } do
      input = Input.from_editor_state(state)
      {state, old_revision} = EditorState.submit_render_intent(state)
      pending = receipt(input, 20, false, layout: :old_layout, intent_revision: old_revision)
      {state, new_revision} = EditorState.submit_render_intent(state)
      changed = %{state | layout: :resized_layout, focus_tree: :new_focus}

      assert new_revision == old_revision + 1
      assert EditorState.apply_renderer_writeback(changed, pending) == changed
    end

    test "receipt from a replaced shell identity is side-effect free", %{state: state} do
      input = Input.from_editor_state(state)
      stale = receipt(input, 10, false, layout: :rendered_layout)

      fake_entry = %Entry{
        id: :fake,
        source: :config,
        module: MingaEditor.Test.FakeShell,
        display_name: "Fake",
        description: "Fake shell",
        capabilities: [:gui],
        generation: 1
      }

      switched = %{
        state
        | shell_runtime:
            Runtime.activate(
              state.shell_runtime,
              fake_entry,
              %{modeline_click_regions: [], tab_bar_click_regions: []}
            )
      }

      assert EditorState.apply_renderer_writeback(switched, stale) == switched
    end

    test "only an applied keyframe receipt clears a pending keyframe request", %{state: state} do
      input = Input.from_editor_state(state)
      state = %{state | keyframe_pending?: true}

      state = EditorState.apply_renderer_writeback(state, receipt(input, 10, false))
      assert state.keyframe_pending?

      state = EditorState.apply_renderer_writeback(state, receipt(input, 11, true))
      refute state.keyframe_pending?
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

    test "does not copy the active buffer cursor into a window showing another buffer", %{
      state: state
    } do
      original_window = Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)
      original_cursor = original_window.cursor
      {:ok, other_buf} = BufferProcess.start_link(content: "other buffer")
      :ok = Minga.Buffer.move_to(other_buf, {0, 5})

      state = put_in(state.workspace.buffers, Buffers.add(state.workspace.buffers, other_buf))
      input = Input.from_editor_state(state)
      synced = Input.sync_active_window_cursor(input)

      window = Map.fetch!(synced.workspace.windows.map, synced.workspace.windows.active)
      assert window.buffer == original_window.buffer
      assert window.cursor == original_cursor
    end

    test "no-op when no active buffer", %{state: state} do
      ws = state.workspace
      state = %{state | workspace: %{ws | buffers: %{ws.buffers | active: nil}}}
      input = Input.from_editor_state(state)

      assert Input.sync_active_window_cursor(input) == input
    end
  end

  defp receipt(input, frame_seq, keyframe?, overrides \\ []) do
    struct!(
      MingaEditor.Renderer.RenderReceipt,
      Keyword.merge(
        [
          layout: nil,
          focus_tree: nil,
          shell_id: input.shell_id,
          shell_identity: input.shell_identity,
          modeline_click_regions: [],
          tab_bar_click_regions: [],
          frame_seq: frame_seq,
          keyframe?: keyframe?,
          render_sent_at: 0,
          intent_revision: 0
        ],
        overrides
      )
    )
  end
end
