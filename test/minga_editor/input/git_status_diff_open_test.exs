defmodule MingaEditor.Input.GitStatusDiffOpenTest do
  @moduledoc "Tests git status diff opening for staged and deleted entries."
  # Mutates the global Git.Stub root mapping because GitStatus resolves the project root internally.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Git
  alias Minga.Git.Stub, as: GitStub
  alias MingaEditor.Input.GitStatus
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  @none 0
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
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

  defp state_with_selected_entry(entry) do
    alias MingaEditor.Shell.Traditional.GitStatus.TuiState

    panel_data = %{
      repo_state: :normal,
      branch: "main",
      ahead: 0,
      behind: 0,
      entries: [entry]
    }

    tui = %TuiState{cursor_index: 1, collapsed: %{}}

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
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
