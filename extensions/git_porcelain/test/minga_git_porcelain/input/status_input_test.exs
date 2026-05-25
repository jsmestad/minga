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
  alias MingaGitPorcelain.Shell.Traditional.GitStatus.TuiState
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
      port_manager: self(),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        keymap_scope: :git_status
      },
      shell_state: %MingaEditor.Shell.Traditional.State{
        git_status_panel: panel_data,
        git_status_tui_state: TuiState.new()
      },
      focus_stack: [MingaEditor.Input.Scoped, MingaEditor.Input.ModeFSM]
    }
  end

  test "git status panel keeps shared data separate from tui state" do
    state = make_state_with_git_panel()
    panel = EditorState.git_status_panel(state)
    assert panel != nil
    refute Map.has_key?(panel, :tui_state)

    tui = ShellState.git_status_tui_state(state.shell_state)
    assert tui != nil
    assert tui.cursor_index == 0
    assert tui.amend_mode == false
    assert tui.discard_confirmation == nil
  end

  test "mouse events passthrough" do
    state = make_state_with_git_panel()
    {:passthrough, _state} = GitStatus.handle_mouse(state, 0, 0, :left, @none, :down, 1)
  end

  test "passthrough for non-git-status scope" do
    state = make_state_with_git_panel()
    state = EditorState.set_keymap_scope(state, :editor)

    {:passthrough, _state} = GitStatus.handle_key(state, @j, @none)
  end
end
