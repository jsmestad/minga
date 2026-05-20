defmodule MingaEditor.UI.Picker.WorkspaceTargetSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileRef
  alias MingaAgent.ProjectView
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.WorkspaceTargetSource
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport

  @moduletag :tmp_dir

  defp file_ref(root, relative_path \\ "lib/auth.ex") do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "original")
    {:ok, ref} = FileRef.from_path(root, relative_path)
    ref
  end

  defp state_with_workspaces(root, active_workspace_id \\ 0) do
    ref = file_ref(root)

    file_tab =
      Tab.new_file(1, "auth.ex") |> Tab.set_file_ref(ref) |> Tab.set_group(active_workspace_id)

    tb = TabBar.new(file_tab, root)
    {tb, agent_a} = TabBar.add_workspace(tb, "Agent: refactor")
    {tb, agent_b} = TabBar.add_workspace(tb, "Agent: tests")

    tb =
      tb
      |> TabBar.update_workspace(0, &Workspace.add_file(&1, ref))
      |> TabBar.update_workspace(agent_a.id, &Workspace.add_file(&1, ref))
      |> TabBar.update_workspace(agent_b.id, &Workspace.add_file(&1, ref))
      |> TabBar.switch_to(1)

    {%EditorState{
       port_manager: self(),
       workspace: %SessionState{viewport: Viewport.new(24, 80)},
       shell_state: %ShellState{tab_bar: tb}
     }, ref, agent_a, agent_b}
  end

  defp picker_context(tab_bar, context) do
    %Context{
      buffers: %MingaEditor.State.Buffers{},
      editing: MingaEditor.VimState.new(),
      search: %MingaEditor.State.Search{},
      viewport: Viewport.new(24, 80),
      tab_bar: tab_bar,
      picker_ui: %{context: context},
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end

  defp transfer_item(operation, source_id, destination_id, file_ref) do
    %Item{
      id:
        {:target,
         %{
           operation: operation,
           source_workspace_id: source_id,
           destination_workspace_id: destination_id,
           file_ref: file_ref
         }},
      label: "target"
    }
  end

  defp workspace(state, id), do: TabBar.get_workspace(state.shell_state.tab_bar, id)

  defp review(state, files) do
    %WorkspaceReview{state: state, changed_files: files}
  end

  describe "candidates/1" do
    test "excludes the current workspace", %{tmp_dir: root} do
      {state, ref, _agent_a, _agent_b} = state_with_workspaces(root)
      tb = state.shell_state.tab_bar

      items =
        WorkspaceTargetSource.candidates(
          picker_context(tb, %{operation: :move, source_workspace_id: 0, file_ref: ref})
        )

      assert Enum.map(items, & &1.label) == ["Agent: refactor", "Agent: tests"]
      refute Enum.any?(items, &(&1.label == workspace(state, 0).label))
    end

    test "shows confirmation choices for draft moves", %{tmp_dir: root} do
      {_state, ref, agent_a, _agent_b} = state_with_workspaces(root)

      items =
        WorkspaceTargetSource.candidates(
          picker_context(nil, %{
            confirm?: true,
            operation: :move,
            source_workspace_id: agent_a.id,
            destination_workspace_id: 0,
            file_ref: ref
          })
        )

      assert Enum.map(items, & &1.label) == ["Continue", "Promote first", "Cancel"]
    end
  end

  describe "on_select/2 copy" do
    test "adds the file to the destination and keeps the source unchanged", %{tmp_dir: root} do
      {state, ref, agent_a, _agent_b} = state_with_workspaces(root)

      state =
        EditorState.set_tab_bar(
          state,
          TabBar.update_workspace(
            state.shell_state.tab_bar,
            agent_a.id,
            &Workspace.remove_file(&1, ref)
          )
        )

      result = WorkspaceTargetSource.on_select(transfer_item(:copy, 0, agent_a.id, ref), state)

      assert Workspace.has_file?(workspace(result, 0), ref)
      assert Workspace.has_file?(workspace(result, agent_a.id), ref)
      assert EditorState.status_msg(result) == "Copied `auth.ex` to `Agent: refactor`"
    end

    test "reports duplicate destination without changing source", %{tmp_dir: root} do
      {state, ref, agent_a, _agent_b} = state_with_workspaces(root)

      result = WorkspaceTargetSource.on_select(transfer_item(:copy, 0, agent_a.id, ref), state)

      assert Workspace.has_file?(workspace(result, 0), ref)
      assert Workspace.has_file?(workspace(result, agent_a.id), ref)
      assert EditorState.status_msg(result) == "`auth.ex` is already in `Agent: refactor`"
    end
  end

  describe "on_select/2 move" do
    test "moves from project workspace to agent workspace", %{tmp_dir: root} do
      {state, ref, agent_a, _agent_b} = state_with_workspaces(root)

      state =
        EditorState.set_tab_bar(
          state,
          TabBar.update_workspace(
            state.shell_state.tab_bar,
            agent_a.id,
            &Workspace.remove_file(&1, ref)
          )
        )

      result = WorkspaceTargetSource.on_select(transfer_item(:move, 0, agent_a.id, ref), state)

      refute Workspace.has_file?(workspace(result, 0), ref)
      assert Workspace.has_file?(workspace(result, agent_a.id), ref)
      assert EditorState.status_msg(result) == "Moved `auth.ex` to `Agent: refactor`"
    end

    test "moves from agent workspace to project workspace when there are no drafts", %{
      tmp_dir: root
    } do
      {state, ref, agent_a, _agent_b} = state_with_workspaces(root, agent_a_id_placeholder())
      state = activate_workspace(state, agent_a.id, ref)

      result = WorkspaceTargetSource.on_select(transfer_item(:move, agent_a.id, 0, ref), state)

      refute Workspace.has_file?(workspace(result, agent_a.id), ref)
      assert Workspace.has_file?(workspace(result, 0), ref)
    end

    test "blocks agent to agent moves", %{tmp_dir: root} do
      {state, ref, agent_a, agent_b} = state_with_workspaces(root)
      state = activate_workspace(state, agent_a.id, ref)

      result =
        WorkspaceTargetSource.on_select(transfer_item(:move, agent_a.id, agent_b.id, ref), state)

      assert Workspace.has_file?(workspace(result, agent_a.id), ref)
      assert Workspace.has_file?(workspace(result, agent_b.id), ref)

      assert EditorState.status_msg(result) ==
               "Move between agent workspaces is not supported in this release. Promote or discard drafts in the source workspace first."
    end

    test "draft moves open confirmation before changing state", %{tmp_dir: root} do
      {state, ref, agent_a, _agent_b} = state_with_workspaces(root)

      state =
        state
        |> activate_workspace(agent_a.id, ref)
        |> update_workspace(agent_a.id, &Workspace.set_review(&1, review(:needs_review, [ref])))

      result = WorkspaceTargetSource.on_select(transfer_item(:move, agent_a.id, 0, ref), state)

      assert Workspace.has_file?(workspace(result, agent_a.id), ref)
      assert {:picker, %{picker_ui: %{source: WorkspaceTargetSource}}} = result.shell_state.modal

      assert EditorState.status_msg(result) ==
               "Drafts for auth.ex will be discarded. Continue / Promote first / Cancel."
    end

    test "cancel after draft confirmation preserves state", %{tmp_dir: root} do
      {state, ref, agent_a, _agent_b} = state_with_workspaces(root)

      state =
        update_workspace(
          state,
          agent_a.id,
          &Workspace.set_review(&1, review(:needs_review, [ref]))
        )

      result =
        WorkspaceTargetSource.on_select(
          %Item{
            id:
              {:confirm, :cancel,
               %{source_workspace_id: agent_a.id, destination_workspace_id: 0, file_ref: ref}},
            label: "Cancel"
          },
          state
        )

      assert Workspace.has_file?(workspace(result, agent_a.id), ref)
      assert workspace(result, agent_a.id).review.changed_files == [ref]
      assert EditorState.status_msg(result) == "Cancelled"
    end

    test "promote first records conflicts without moving", %{tmp_dir: root} do
      {state, ref, agent_a, _agent_b} = state_with_workspaces(root)
      {:ok, view} = ProjectView.overlay(root)
      :ok = ProjectView.write_file(view, ref.relative_path, "agent version")
      File.write!(Path.join(root, ref.relative_path), "human version")

      state =
        update_workspace(state, agent_a.id, fn workspace ->
          workspace
          |> Workspace.set_project_view(view)
          |> Workspace.set_review(review(:needs_review, [ref]))
        end)

      result =
        WorkspaceTargetSource.on_select(
          %Item{
            id:
              {:confirm, :promote_first,
               %{
                 operation: :move,
                 source_workspace_id: agent_a.id,
                 destination_workspace_id: 0,
                 file_ref: ref
               }},
            label: "Promote first"
          },
          state
        )

      assert Workspace.has_file?(workspace(result, agent_a.id), ref)
      assert workspace(result, agent_a.id).review.state == :conflict
      assert workspace(result, agent_a.id).review.conflict_files == [ref]
      assert EditorState.status_msg(result) =~ "Workspace promote found conflicts"
    end

    test "continue after draft confirmation discards the file draft and moves", %{tmp_dir: root} do
      {state, ref, agent_a, _agent_b} = state_with_workspaces(root)
      {:ok, view} = ProjectView.overlay(root)
      :ok = ProjectView.write_file(view, ref.relative_path, "draft")

      other_ref = file_ref(root, "lib/other.ex")
      :ok = ProjectView.write_file(view, other_ref.relative_path, "other draft")

      state =
        state
        |> update_workspace(agent_a.id, fn workspace ->
          workspace
          |> Workspace.set_project_view(view)
          |> Workspace.set_review(review(:needs_review, [ref, other_ref]))
        end)

      result =
        WorkspaceTargetSource.on_select(
          %Item{
            id:
              {:confirm, :continue,
               %{
                 operation: :move,
                 source_workspace_id: agent_a.id,
                 destination_workspace_id: 0,
                 file_ref: ref
               }},
            label: "Continue"
          },
          state
        )

      refute Workspace.has_file?(workspace(result, agent_a.id), ref)
      assert Workspace.has_file?(workspace(result, 0), ref)
      assert workspace(result, agent_a.id).review.changed_files == [other_ref]
      assert {:ok, [%{path: "lib/other.ex"}]} = ProjectView.diff(view)
    end
  end

  defp agent_a_id_placeholder, do: 1

  defp activate_workspace(state, workspace_id, file_ref) do
    tb =
      state.shell_state.tab_bar
      |> TabBar.update_tab(1, fn tab ->
        tab
        |> Tab.set_group(workspace_id)
        |> Tab.set_file_ref(file_ref)
      end)

    EditorState.set_tab_bar(state, tb)
  end

  defp update_workspace(state, workspace_id, fun) do
    EditorState.set_tab_bar(
      state,
      TabBar.update_workspace(state.shell_state.tab_bar, workspace_id, fun)
    )
  end
end
