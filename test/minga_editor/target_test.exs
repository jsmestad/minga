defmodule MingaEditor.TargetTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion
  alias Minga.Editing.Completion.Item, as: CompletionItem
  alias Minga.Mode.CommandState
  alias Minga.Project.FileTree
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.UIState
  alias MingaEditor.KeyDispatch
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Target
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.WorkspaceWorkflow

  test "every identity kind resolves its named resident reference, not the active selection" do
    state = TestHelpers.base_state()
    tab = Tab.new_file(17, "named.ex")
    tabs = WorkspaceWorkflow.install_tab_bar(state, TabBar.new(tab))
    window = state.workspace.windows.map[1]
    item = CompletionItem.from_fields(:test, %{label: "named"})
    completion = Completion.new([item], {0, 0})
    payload = CompletionPayload.new(17, completion: completion)
    completions = ModalWorkflow.open(state, {:completion, payload})
    {pickers, picker_generation, picker_id, action_id} = picker_state(state)

    entry = %{
      path: "/project/named.ex",
      name: "named.ex",
      dir?: false,
      depth: 0,
      last_child?: true,
      guides: []
    }

    tree = FileTree.new("/project") |> FileTree.put_entries([entry])
    file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)
    trees = %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree)}
    commands = command_state(state)
    command_payload = ModalWorkflow.command_completion(commands)
    candidate = hd(command_payload.candidates)
    {timelines, timeline, timeline_entry} = timeline_state(state)
    timeline_id = EditTimeline.entry_id("/project/named.ex", timeline_entry)

    cases = [
      {tabs, {:tab, 17}, {:tab, tab}},
      {state, {:window, 1, window.accessibility_generation}, {:window, window}},
      {completions,
       {:surface_item, :completion, CompletionPayload.presentation_generation(payload),
        CompletionItem.wire_id(item)}, {:completion, completion}},
      {pickers, {:surface_item, :picker, picker_generation, <<picker_id::32>>},
       {:picker_item, picker_generation, picker_id}},
      {pickers, {:surface_item, :picker, picker_generation, <<action_id::32>>},
       {:picker_action, picker_generation, action_id}},
      {trees, {:surface_item, :file_tree, file_tree.presentation_generation, entry.path},
       {:file_tree, tree, entry}},
      {trees, {:surface_item, :file_tree, file_tree.presentation_generation, ""},
       {:file_tree, tree, nil}},
      {commands,
       {:surface_item, :command_completion, command_payload.generation, candidate.label},
       {:command_completion, candidate.label}},
      {timelines, {:timeline_entry, timeline.generation, timeline_id},
       {:timeline_entry, "/project/named.ex", timeline_entry}},
      {timelines, {:surface_item, :timeline, timeline.generation, timeline_id},
       {:timeline_entry, "/project/named.ex", timeline_entry}}
    ]

    for {snapshot, target, expected} <- cases do
      assert Target.resolve(snapshot, target) == {:ok, expected}, inspect(target)
    end
  end

  test "missing, stale, and mismatched targets return typed errors without fallback" do
    state = TestHelpers.base_state()
    window = state.workspace.windows.map[1]
    item = CompletionItem.from_fields(:test, %{label: "named"})
    payload = CompletionPayload.new(1, completion: Completion.new([item], {0, 0}))
    completions = ModalWorkflow.open(state, {:completion, payload})
    completion_generation = CompletionPayload.presentation_generation(payload)
    {pickers, picker_generation, picker_id, _action_id} = picker_state(state)
    tree = FileTree.new("/project") |> FileTree.put_entries([])
    file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)
    trees = %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree)}
    commands = command_state(state)
    command_payload = ModalWorkflow.command_completion(commands)
    candidate = hd(command_payload.candidates)
    {timelines, timeline, entry} = timeline_state(state)
    timeline_id = EditTimeline.entry_id("/project/named.ex", entry)

    mismatched_window = %{
      state
      | workspace: %{state.workspace | buffers: %{state.workspace.buffers | active: nil}}
    }

    cases = [
      {state, {:tab, 999}, :not_found},
      {state, {:window, 999, 1}, :not_found},
      {state, {:window, 1, window.accessibility_generation + 1}, :stale_generation},
      {mismatched_window, {:window, 1, window.accessibility_generation}, :target_mismatch},
      {completions, {:surface_item, :completion, completion_generation, "missing"}, :not_found},
      {completions,
       {:surface_item, :completion, completion_generation + 1, CompletionItem.wire_id(item)},
       :stale_generation},
      {pickers, {:surface_item, :completion, completion_generation, CompletionItem.wire_id(item)},
       :target_mismatch},
      {pickers, {:surface_item, :picker, picker_generation, <<0::32>>}, :not_found},
      {pickers, {:surface_item, :picker, picker_generation + 1, <<picker_id::32>>},
       :stale_generation},
      {pickers, {:surface_item, :picker, picker_generation, "invalid"}, :target_mismatch},
      {trees, {:surface_item, :file_tree, file_tree.presentation_generation, "missing"},
       :not_found},
      {trees, {:surface_item, :file_tree, file_tree.presentation_generation + 1, ""},
       :stale_generation},
      {commands, {:surface_item, :command_completion, command_payload.generation, "missing"},
       :not_found},
      {commands,
       {:surface_item, :command_completion, command_payload.generation + 1, candidate.label},
       :stale_generation},
      {state, {:surface_item, :command_completion, command_payload.generation, candidate.label},
       :target_mismatch},
      {timelines, {:timeline_entry, timeline.generation, "missing"}, :not_found},
      {timelines, {:timeline_entry, timeline.generation + 1, timeline_id}, :stale_generation},
      {timelines, {:timeline_entry, timeline.generation, nil}, :target_mismatch},
      {state, {:surface_item, :unknown, 1, "named"}, :target_mismatch}
    ]

    for {snapshot, target, reason} <- cases do
      assert Target.resolve(snapshot, target) == {:error, reason}, inspect(target)
    end
  end

  test "picker items and source actions reject a buffer retired after the offer" do
    state = TestHelpers.base_state()
    buffer = state.workspace.buffers.active
    item = %Item{id: {:buffer, buffer}, label: "Offered buffer"}
    {state, generation, item_id, action_id} = picker_state(state, item)
    buffers = MingaEditor.State.Buffers.remove(state.workspace.buffers, buffer)
    retired = %{state | workspace: SessionState.set_buffers(state.workspace, buffers)}

    for id <- [item_id, action_id] do
      assert Target.resolve(retired, {:surface_item, :picker, generation, <<id::32>>}) ==
               {:error, :not_found}
    end
  end

  test "command input changed before its overlay refresh cannot accept the previous offer" do
    state = command_state(TestHelpers.base_state())
    payload = ModalWorkflow.command_completion(state)
    candidate = hd(payload.candidates)

    workspace =
      SessionState.transition_mode(state.workspace, :command, CommandState.new("different"))

    changed = %{state | workspace: workspace}

    assert Target.resolve(
             changed,
             {:surface_item, :command_completion, payload.generation, candidate.label}
           ) ==
             {:error, :stale_generation}
  end

  defp command_state(state) do
    %{
      state
      | workspace: SessionState.transition_mode(state.workspace, :command, CommandState.new("e"))
    }
    |> KeyDispatch.refresh_command_completion()
  end

  defp picker_state(state, item \\ %Item{id: :named, label: "Named"}) do
    picker = Picker.new([item])

    picker_state =
      %PickerState{picker: picker}
      |> PickerState.begin_query_session()
      |> PickerState.open_action_menu([{"Open", :open}], item)

    [{id, _, _}] = picker_state.activation_offer.items
    [{action_id, _, _}] = picker_state.activation_offer.actions
    state = ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
    {state, picker_state.activation_offer.generation, id, action_id}
  end

  defp timeline_state(state) do
    timeline =
      EditTimeline.record_edit(
        EditTimeline.new(),
        "/project/named.ex",
        "tool",
        "edit",
        "old",
        "new"
      )

    [entry] = EditTimeline.entries_for(timeline, "/project/named.ex")
    ui = UIState.replace_edit_timeline(state.workspace.agent_ui, timeline)
    state = MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)
    {state, timeline, entry}
  end
end
