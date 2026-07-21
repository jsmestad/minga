defmodule MingaGitPorcelain.Input.GitStatusDiffOpenTest do
  @moduledoc "Tests git status diff opening for staged and deleted entries."
  # Mutates the global Git.Stub root mapping because GitStatus resolves the project root internally.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Git
  alias Minga.Git.Stub, as: GitStub
  alias MingaGitPorcelain.Input.GitStatus
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  @none 0
  @effect_timeout 1_000
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    MingaGitPorcelain.Feature.register_contributions()
    project_root = Minga.Project.resolve_root()
    GitStub.set_root(project_root, dir)

    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: task_supervisor, observer: self()},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())

    on_exit(fn ->
      GitStub.clear(project_root)
      GitStub.clear(dir)
    end)

    {:ok, git_root: dir, scheduler: scheduler}
  end

  test "previewing a staged status entry opens the staged index diff", %{
    git_root: git_root,
    scheduler: scheduler
  } do
    rel_path = "file.txt"
    File.write!(Path.join(git_root, rel_path), "worktree\n")
    GitStub.set_head(git_root, rel_path, "head\n")
    GitStub.set_staged(git_root, rel_path, "staged\n")

    entry = %Git.StatusEntry{path: rel_path, status: :modified, staged: true}
    state = state_with_selected_entry(entry, scheduler)

    {:handled, state} = GitStatus.handle_key(state, ?p, @none)
    active_buf = state.workspace.buffers.active

    assert Buffer.buffer_name(active_buf) == "file.txt [diff:staged]"
    assert buffer_content(active_buf) =~ "staged"
    refute buffer_content(active_buf) =~ "worktree"
  end

  test "previewing a deleted status entry opens a deletion diff without reading the missing file",
       %{git_root: git_root, scheduler: scheduler} do
    rel_path = "deleted.txt"
    GitStub.set_head(git_root, rel_path, "removed\n")

    entry = %Git.StatusEntry{path: rel_path, status: :deleted, staged: true}
    state = state_with_selected_entry(entry, scheduler)

    {:handled, state} = GitStatus.handle_key(state, ?p, @none)
    active_buf = state.workspace.buffers.active

    assert Buffer.buffer_name(active_buf) == "deleted.txt [diff:staged]"
    assert buffer_content(active_buf) =~ "removed"
    refute MingaEditor.Shell.Traditional.NoticeWorkflow.message(state) =~ "Could not read"
  end

  test "GUI open diff uses section when duplicate paths exist", %{
    git_root: git_root,
    scheduler: scheduler
  } do
    rel_path = "both.txt"
    File.write!(Path.join(git_root, rel_path), "worktree\n")
    GitStub.set_head(git_root, rel_path, "head\n")
    GitStub.set_staged(git_root, rel_path, "staged\n")

    staged_entry = %Git.StatusEntry{path: rel_path, status: :modified, staged: true}
    changed_entry = %Git.StatusEntry{path: rel_path, status: :modified, staged: false}

    {:noreply, staged_pending} =
      MingaEditor.handle_info(
        {:minga_input, {:gui_action, {:git_open_diff, rel_path, 0}}},
        state_with_panel_entries([changed_entry, staged_entry], scheduler)
      )

    staged_state = receive_effect(staged_pending, scheduler)
    staged_buf = staged_state.workspace.buffers.active
    assert Buffer.buffer_name(staged_buf) == "both.txt [diff:staged]"
    assert buffer_content(staged_buf) =~ "staged"
    refute buffer_content(staged_buf) =~ "worktree"

    {:noreply, changed_pending} =
      MingaEditor.handle_info(
        {:minga_input, {:gui_action, {:git_open_diff, rel_path, 1}}},
        state_with_panel_entries([staged_entry, changed_entry], scheduler)
      )

    changed_state = receive_effect(changed_pending, scheduler)
    changed_buf = changed_state.workspace.buffers.active
    assert Buffer.buffer_name(changed_buf) == "both.txt [diff:unstaged]"
    assert buffer_content(changed_buf) =~ "worktree"
    refute buffer_content(changed_buf) =~ "staged"
  end

  defp state_with_selected_entry(entry, scheduler),
    do: state_with_panel_entries([entry], scheduler)

  defp state_with_panel_entries(entries, scheduler) do
    alias MingaEditor.GitStatus.TUIState, as: TuiState

    panel_data = %{
      repo_state: :normal,
      branch: "main",
      ahead: 0,
      behind: 0,
      entries: entries
    }

    tui = %TuiState{cursor_index: 1, collapsed: %{}}

    %EditorState{
      effect_scheduler: scheduler,
      frontend: %MingaEditor.State.Frontend{port_manager: self(), rendering: :disabled},
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        keymap_scope: :git_status
      },
      interaction: %MingaEditor.State.Interaction{}
    }
    |> SidebarWorkflow.replace_git_status(GitStatusPanel.new(panel_data))
    |> SidebarWorkflow.replace_git_status_tui(tui)
  end

  defp receive_effect(state, scheduler) do
    assert_receive {:effect_lifecycle, %Outcome{status: :running} = running}, @effect_timeout
    {:noreply, state} = MingaEditor.handle_info({:effect_lifecycle, running}, state)

    assert_receive {:effect_result, ^scheduler, %Outcome{} = outcome}, @effect_timeout
    {:noreply, state} = MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)
    state
  end

  defp buffer_content(buf) do
    {content, _cursor} = Buffer.content_and_cursor(buf)
    content
  end
end
