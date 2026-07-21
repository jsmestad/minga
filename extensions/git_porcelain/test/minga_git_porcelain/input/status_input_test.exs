defmodule MingaGitPorcelain.Input.GitStatusInputTest do
  @moduledoc """
  Tests for git status panel input handler.

  Verifies that git status keybindings work correctly through the input handler.
  These tests verify the state mutations directly without going through the full
  keymap system.
  """
  use ExUnit.Case, async: true

  alias Minga.Git
  alias MingaGitPorcelain.Input.GitStatus
  alias MingaEditor.GitStatus.TUIState, as: TuiState
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  # Keycodes
  @j ?j
  @none 0

  setup do
    MingaGitPorcelain.Feature.register_contributions()
    :ok
  end

  defp make_state_with_git_panel do
    entries = [
      %Git.StatusEntry{path: "file1.txt", status: :modified, staged: false},
      %Git.StatusEntry{path: "file2.txt", status: :modified, staged: true},
      %Git.StatusEntry{path: "file3.txt", status: :untracked, staged: false}
    ]

    panel_data = %{
      repo_state: :normal,
      branch: "main",
      ahead: 0,
      behind: 0,
      entries: entries
    }

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        keymap_scope: :git_status
      },
      interaction: %MingaEditor.State.Interaction{}
    }
    |> SidebarWorkflow.replace_git_status(GitStatusPanel.new(panel_data))
    |> SidebarWorkflow.replace_git_status_tui(TuiState.new())
  end

  test "git status panel keeps shared data separate from tui state" do
    state = make_state_with_git_panel()
    panel = SidebarWorkflow.git_status_panel(state)
    assert panel != nil
    refute Map.has_key?(panel, :tui_state)

    tui = ShellState.git_status_tui_state(Runtime.state(state.shell_runtime))
    assert tui != nil
    assert tui.cursor_index == 0
    assert tui.discard_confirmation == nil
  end

  test "passthrough for non-git-status scope" do
    state = make_state_with_git_panel()

    state = %{
      state
      | workspace: MingaEditor.Session.State.set_keymap_scope(state.workspace, :editor)
    }

    {:passthrough, _state} = GitStatus.handle_key(state, @j, @none)
  end
end
