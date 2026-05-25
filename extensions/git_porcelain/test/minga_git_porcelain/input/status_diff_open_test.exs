defmodule MingaGitPorcelain.Input.GitStatusDiffOpenTest do
  @moduledoc "Tests git status diff opening for staged and deleted entries."
  # Mutates the global Git.Stub root mapping because GitStatus resolves the project root internally.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Git
  alias Minga.Git.Stub, as: GitStub
  alias MingaGitPorcelain.Input.GitStatus
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  @none 0
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    MingaGitPorcelain.Feature.register_contributions()
    project_root = Minga.Project.resolve_root()
    GitStub.set_root(project_root, dir)

    on_exit(fn ->
      GitStub.clear(project_root)
      GitStub.clear(dir)
    end)

    {:ok, git_root: dir}
  end

  test "previewing a staged status entry opens the staged index diff", %{git_root: git_root} do
    rel_path = "file.txt"
    File.write!(Path.join(git_root, rel_path), "worktree\n")
    GitStub.set_head(git_root, rel_path, "head\n")
    GitStub.set_staged(git_root, rel_path, "staged\n")

    entry = %Git.StatusEntry{path: rel_path, status: :modified, staged: true}
    state = state_with_selected_entry(entry)

    {:handled, state} = GitStatus.handle_key(state, ?p, @none)
    active_buf = state.workspace.buffers.active

    assert Buffer.buffer_name(active_buf) == "file.txt [diff:staged]"
    assert buffer_content(active_buf) =~ "staged"
    refute buffer_content(active_buf) =~ "worktree"
  end

  test "previewing a deleted status entry opens a deletion diff without reading the missing file",
       %{
         git_root: git_root
       } do
    rel_path = "deleted.txt"
    GitStub.set_head(git_root, rel_path, "removed\n")

    entry = %Git.StatusEntry{path: rel_path, status: :deleted, staged: true}
    state = state_with_selected_entry(entry)

    {:handled, state} = GitStatus.handle_key(state, ?p, @none)
    active_buf = state.workspace.buffers.active

    assert Buffer.buffer_name(active_buf) == "deleted.txt [diff:staged]"
    assert buffer_content(active_buf) =~ "removed"
    refute EditorState.status_msg(state) =~ "Could not read"
  end

  test "GUI open diff uses section when duplicate paths exist", %{git_root: git_root} do
    rel_path = "both.txt"
    File.write!(Path.join(git_root, rel_path), "worktree\n")
    GitStub.set_head(git_root, rel_path, "head\n")
    GitStub.set_staged(git_root, rel_path, "staged\n")

    staged_entry = %Git.StatusEntry{path: rel_path, status: :modified, staged: true}
    changed_entry = %Git.StatusEntry{path: rel_path, status: :modified, staged: false}

    {:noreply, staged_state} =
      MingaEditor.handle_info(
        {:minga_input, {:gui_action, {:git_open_diff, rel_path, 0}}},
        state_with_panel_entries([changed_entry, staged_entry])
      )

    staged_buf = staged_state.workspace.buffers.active
    assert Buffer.buffer_name(staged_buf) == "both.txt [diff:staged]"
    assert buffer_content(staged_buf) =~ "staged"
    refute buffer_content(staged_buf) =~ "worktree"

    {:noreply, changed_state} =
      MingaEditor.handle_info(
        {:minga_input, {:gui_action, {:git_open_diff, rel_path, 1}}},
        state_with_panel_entries([staged_entry, changed_entry])
      )

    changed_buf = changed_state.workspace.buffers.active
    assert Buffer.buffer_name(changed_buf) == "both.txt [diff:unstaged]"
    assert buffer_content(changed_buf) =~ "worktree"
    refute buffer_content(changed_buf) =~ "staged"
  end

  defp state_with_selected_entry(entry), do: state_with_panel_entries([entry])

  defp state_with_panel_entries(entries) do
    alias MingaGitPorcelain.Shell.Traditional.GitStatus.TuiState

    panel_data = %{
      repo_state: :normal,
      branch: "main",
      ahead: 0,
      behind: 0,
      entries: entries
    }

    tui = %TuiState{cursor_index: 1, collapsed: %{}}

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        keymap_scope: :git_status
      },
      shell_state: %MingaEditor.Shell.Traditional.State{
        git_status_panel: panel_data,
        git_status_tui_state: tui
      },
      focus_stack: [MingaEditor.Input.Scoped, MingaEditor.Input.ModeFSM]
    }
  end

  defp buffer_content(buf) do
    {content, _cursor} = Buffer.content_and_cursor(buf)
    content
  end
end
