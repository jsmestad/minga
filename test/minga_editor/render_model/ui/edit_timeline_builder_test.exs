defmodule MingaEditor.RenderModel.UI.EditTimelineBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.EditTimelineBuilder
  alias Minga.RenderModel.UI.EditTimeline
  alias MingaEditor.Agent.EditTimeline, as: EditTimelineState
  alias MingaEditor.Agent.FileChange
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.TestHelpers

  describe "build/1" do
    test "builds a hidden timeline when there is no agent_ui" do
      assert %EditTimeline{visible?: false, entries: []} = EditTimelineBuilder.build(context(nil))
    end

    test "an empty Agent workspace mounts the timeline before any background file arrives" do
      ctx = context(EditTimelineState.new())

      assert %EditTimeline{visible?: true, files: [], entries: []} =
               EditTimelineBuilder.build(ctx)
    end

    test "builds aggregate file entries for multi-file turns without an active buffer path" do
      timeline =
        EditTimelineState.new()
        |> EditTimelineState.record_edit(file_change("lib/a.ex", "tc1", "old\n", "new\n"))
        |> EditTimelineState.record_edit(file_change("lib/b.ex", "tc2", "one\n", "one\ntwo\n"))

      ctx = context(timeline)

      assert %EditTimeline{
               visible?: true,
               entries: [],
               files: [
                 %EditTimeline.FileEntry{
                   path: "lib/a.ex",
                   entry_count: 1,
                   lines_added: 1,
                   lines_removed: 1,
                   review_status: :pending
                 },
                 %EditTimeline.FileEntry{
                   path: "lib/b.ex",
                   entry_count: 1,
                   lines_added: 1,
                   lines_removed: 0,
                   review_status: :pending
                 }
               ]
             } = EditTimelineBuilder.build(ctx)

      assert EditTimelineBuilder.build(ctx).generation == timeline.generation
    end

    test "long recovered paths fit the wire frame without removing files from browsing" do
      common = String.duplicate("directory/", 40)
      counts = Map.new(1..300, &{"lib/#{common}file-#{&1}.ex", 1})
      timeline = EditTimelineState.recover_files(EditTimelineState.new(), counts)
      model = EditTimelineBuilder.build(context(timeline))

      assert {<<0x9B, size::16, payload::binary>>, _caches} =
               Minga.Frontend.Adapter.GUI.EditTimelineEncoder.encode(
                 model,
                 Minga.Frontend.Adapter.GUI.Caches.new()
               )

      assert byte_size(payload) == size
      assert length(model.files) < 255
      files = EditTimelineState.file_summaries(timeline)
      shown = MapSet.new(model.files, & &1.path)
      %{path: omitted_path} = Enum.find(files, &(not MapSet.member?(shown, &1.path)))

      picker_context =
        MingaEditor.UI.Picker.Context.from_editor_state(TestHelpers.base_state(), %{
          files: files,
          origin: :fixture
        })

      picker =
        picker_context
        |> MingaEditor.UI.Picker.AgentChangesSource.candidates()
        |> MingaEditor.UI.Picker.new()
        |> MingaEditor.UI.Picker.filter(omitted_path)

      assert %{id: ^omitted_path} = MingaEditor.UI.Picker.selected_item(picker)
    end

    @tag :tmp_dir
    test "projects path-bound entry ids and preserves generation while navigating", %{
      tmp_dir: tmp_dir
    } do
      first_path = Path.join(tmp_dir, "first.ex")
      second_path = Path.join(tmp_dir, "second.ex")
      File.write!(first_path, "first")
      File.write!(second_path, "second")

      first_buffer =
        start_supervised!({Minga.Buffer.Process, file_path: first_path}, id: :first)

      second_buffer =
        start_supervised!({Minga.Buffer.Process, file_path: second_path}, id: :second)

      timeline =
        EditTimelineState.new()
        |> EditTimelineState.record_edit(file_change(first_path, "shared-call", "old", "first"))
        |> EditTimelineState.record_edit(file_change(second_path, "shared-call", "old", "second"))

      first_model = EditTimelineBuilder.build(context(timeline, first_buffer))
      second_model = EditTimelineBuilder.build(context(timeline, second_buffer))
      [first_entry] = EditTimelineState.entries_for(timeline, first_path)
      [second_entry] = EditTimelineState.entries_for(timeline, second_path)

      assert [%EditTimeline.Entry{entry_id: first_id, index: 0}] = first_model.entries
      assert [%EditTimeline.Entry{entry_id: second_id, index: 0}] = second_model.entries
      assert first_id == EditTimelineState.entry_id(first_path, first_entry)
      assert second_id == EditTimelineState.entry_id(second_path, second_entry)
      assert first_id != second_id
      assert first_model.generation == timeline.generation
      assert second_model.generation == timeline.generation

      viewed = EditTimelineState.set_viewing(timeline, first_path, 0)
      viewed_model = EditTimelineBuilder.build(context(viewed, first_buffer))
      assert viewed_model.viewing_index == 0
      assert viewed_model.entries == first_model.entries
      assert viewed_model.generation == first_model.generation
    end
  end

  defp file_change(path, tool_call_id, before_content, after_content) do
    %FileChange{
      path: path,
      tool_call_id: tool_call_id,
      tool_name: "edit_file",
      before_content: before_content,
      after_content: after_content
    }
  end

  defp context(timeline, buffer \\ nil) do
    state = TestHelpers.base_state(port_manager: nil)
    id = state.workspace.windows.active
    window = MingaEditor.Window.new_agent_chat(id, 24, 80)
    windows = MingaEditor.State.Windows.replace_window(state.workspace.windows, id, window)
    state = %{state | workspace: MingaEditor.Session.State.set_windows(state.workspace, windows)}
    ctx = Context.from_editor_state(state)

    agent_ui =
      if timeline == nil,
        do: nil,
        else: UIState.replace_edit_timeline(UIState.new(), timeline)

    buffers = %{
      ctx.workspace.buffers
      | active: buffer,
        list: if(buffer == nil, do: [], else: [buffer]),
        active_index: 0
    }

    workspace = %{ctx.workspace | agent_ui: agent_ui, buffers: buffers}

    %{ctx | workspace: workspace, intent: %{ctx.intent | workspace: workspace}}
  end
end
