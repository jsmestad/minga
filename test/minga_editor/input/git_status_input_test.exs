defmodule MingaEditor.Input.GitStatusInputTest do
  @moduledoc """
  Tests for git status panel input handler.

  Verifies that git status keybindings work correctly through the input handler.
  These tests verify the state mutations directly without going through the full
  keymap system.
  """
  use ExUnit.Case, async: true

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Input.GitStatus
  alias MingaEditor.Viewport
  alias Minga.Git

  # Keycodes
  @j ?j
  @none 0

  defp make_state_with_git_panel do
    entries = [
      %Git.StatusEntry{path: "file1.txt", status: :modified, staged: false},
      %Git.StatusEntry{path: "file2.txt", status: :modified, staged: true},
      %Git.StatusEntry{path: "file3.txt", status: :untracked, staged: false}
    ]

    # Initialize TUI state with flat entries
    tui_state = %MingaEditor.Input.GitStatus.TuiState{
      cursor_index: 0,
      collapsed: %{},
      flat_entries: [
        {:section_header, :conflicts, 0},
        {:section_header, :staged, 1},
        {:file, :staged, Enum.at(entries, 1)},
        {:section_header, :changes, 1},
        {:file, :changes, Enum.at(entries, 0)},
        {:section_header, :untracked, 1},
        {:file, :untracked, Enum.at(entries, 2)}
      ],
      entries: entries,
      discard_confirmation: nil,
      amend_mode: false
    }

    panel_data = %{
      repo_state: :normal,
      branch: "main",
      ahead: 0,
      behind: 0,
      entries: entries,
      tui_state: tui_state
    }

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        keymap_scope: :git_status
      },
      shell_state: %MingaEditor.Shell.Traditional.State{
        git_status_panel: panel_data
      },
      focus_stack: [MingaEditor.Input.Scoped, MingaEditor.Input.ModeFSM]
    }
  end

  test "git status panel initializes with tui state" do
    state = make_state_with_git_panel()
    panel = EditorState.git_status_panel(state)
    assert panel != nil
    tui = Map.get(panel, :tui_state)
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
    state = EditorState.update_workspace(state, fn ws -> %{ws | keymap_scope: :editor} end)

    {:passthrough, _state} = GitStatus.handle_key(state, @j, @none)
  end
end
