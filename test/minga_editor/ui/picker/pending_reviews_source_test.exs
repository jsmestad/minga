defmodule MingaEditor.UI.Picker.PendingReviewsSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace, as: Workspace
  alias MingaEditor.State.Workspace.Persistence
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.PendingReviewsSource
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  @moduletag :tmp_dir

  defp fake_context(tab_bar) do
    %Context{
      buffers: %Buffers{list: [], active: nil, active_index: 0},
      editing: VimState.new(),
      file_tree: nil,
      search: %Search{},
      viewport: Viewport.new(80, 24),
      tab_bar: tab_bar,
      agent_session: nil,
      picker_ui: %{},
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content},
      id: {:pending_reviews_buffer, :erlang.unique_integer([:positive])}
    )
  end

  defp editor_state(tab_bar, buffer, mode \\ :normal) do
    %EditorState{
      port_manager: nil,
      workspace: %SessionState{
        viewport: Viewport.new(80, 24),
        editing: %VimState{mode: mode, mode_state: Minga.Mode.initial_state()},
        buffers: %Buffers{list: [buffer], active: buffer, active_index: 0},
        keymap_scope: :editor
      },
      shell_state: %ShellState{tab_bar: tab_bar}
    }
  end

  defp put_workspace(tab_bar, id, fun) do
    TabBar.update_workspace(tab_bar, id, fun)
  end

  defp review(state, changed_count \\ 1, conflict_count \\ 0) do
    %WorkspaceReview{
      state: state,
      changed_files: List.duplicate(file_ref(), changed_count),
      conflict_files: List.duplicate(file_ref(), conflict_count)
    }
  end

  defp file_ref do
    {:ok, ref} = Minga.Project.FileRef.from_path("/tmp/minga", "lib/a.ex")
    ref
  end

  defp touch_workspace(workspace, time) do
    :ok = Persistence.write(workspace, workspace.project_root)
    workspace.project_root |> Persistence.path_for(workspace.id) |> File.touch!(time)
    workspace
  end

  describe "candidates/1" do
    test "returns empty-state item when no workspaces await review" do
      items = PendingReviewsSource.candidates(fake_context(TabBar.new(Tab.new_file(1, "a.ex"))))

      assert [%Item{id: :empty, label: "No workspaces awaiting review"}] = items
    end

    test "lists needs_review workspaces with counts and timestamp", %{tmp_dir: dir} do
      tb = TabBar.new(Tab.new_file(1, "a.ex"), dir)
      {tb, workspace} = TabBar.add_workspace(tb, "Review me")

      tb =
        put_workspace(tb, workspace.id, fn ws ->
          ws
          |> Workspace.set_review(review(:needs_review, 2, 0))
          |> touch_workspace({{2026, 5, 20}, {12, 30, 0}})
        end)

      [item] = PendingReviewsSource.candidates(fake_context(tb))

      assert item.label == "Review me"
      assert item.description =~ "Needs review"
      assert item.description =~ "2 draft file(s)"
      assert item.description =~ "0 conflict file(s)"
      assert item.description =~ "Last activity"
    end

    test "sorts conflicts first, then needs_review by most recent activity", %{tmp_dir: dir} do
      tb = TabBar.new(Tab.new_file(1, "a.ex"), dir)
      {tb, older_conflict} = TabBar.add_workspace(tb, "Old conflict")
      {tb, newer_review} = TabBar.add_workspace(tb, "New review")
      {tb, newer_conflict} = TabBar.add_workspace(tb, "New conflict")

      tb =
        tb
        |> put_workspace(older_conflict.id, fn ws ->
          ws
          |> Workspace.set_review(review(:conflict, 1, 1))
          |> touch_workspace({{2026, 5, 20}, {10, 0, 0}})
        end)
        |> put_workspace(newer_review.id, fn ws ->
          ws
          |> Workspace.set_review(review(:needs_review, 1, 0))
          |> touch_workspace({{2026, 5, 20}, {12, 0, 0}})
        end)
        |> put_workspace(newer_conflict.id, fn ws ->
          ws
          |> Workspace.set_review(review(:conflict, 1, 2))
          |> touch_workspace({{2026, 5, 20}, {13, 0, 0}})
        end)

      assert Enum.map(PendingReviewsSource.candidates(fake_context(tb)), & &1.label) == [
               "New conflict",
               "Old conflict",
               "New review"
             ]
    end
  end

  describe "on_select/2" do
    test "switches to a restored pending workspace with no tabs" do
      buf = start_buffer("a")
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, workspace} = TabBar.add_workspace(tb, "Restored review")
      tb = put_workspace(tb, workspace.id, &Workspace.set_review(&1, review(:needs_review)))
      state = editor_state(tb, buf)

      switched =
        PendingReviewsSource.on_select(
          %Item{id: {workspace.id, 0}, label: "Restored review"},
          state
        )

      assert TabBar.active_workspace_id(switched.shell_state.tab_bar) == workspace.id
      assert [tab] = TabBar.tabs_in_workspace(switched.shell_state.tab_bar, workspace.id)
      assert tab.kind == :agent
    end

    test "switches to the selected workspace" do
      buf_a = start_buffer("a")
      buf_b = start_buffer("b")

      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, tab2} = TabBar.add(tb, :file, "b.ex")
      {tb, workspace} = TabBar.add_workspace(tb, "Needs review")

      tb =
        tb
        |> TabBar.move_tab_to_workspace(tab2.id, workspace.id)
        |> TabBar.switch_to(1)
        |> put_workspace(workspace.id, &Workspace.set_review(&1, review(:needs_review)))

      target_context =
        editor_state(nil, buf_b, :insert)
        |> EditorState.snapshot_tab_context()

      tb = TabBar.update_context(tb, tab2.id, target_context)
      state = editor_state(tb, buf_a)

      switched =
        PendingReviewsSource.on_select(%Item{id: {workspace.id, 0}, label: "Needs review"}, state)

      assert switched.shell_state.tab_bar.active_id == tab2.id
      assert switched.workspace.buffers.active == buf_b
    end
  end

  describe "on_cancel/1" do
    test "preserves current workspace" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      state = editor_state(tb, start_buffer("a"))

      assert PendingReviewsSource.on_cancel(state) == state
    end
  end
end
