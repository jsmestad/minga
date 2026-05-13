defmodule MingaEditor.Handlers.FileEventHandlerTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Handlers.FileEventHandler`.

  Uses `RenderPipeline.TestHelpers.base_state/1` to construct state
  without starting a GenServer.
  """

  use ExUnit.Case, async: true

  alias Minga.Git.StatusEntry
  alias MingaEditor.Handlers.FileEventHandler
  alias MingaEditor.Shell.Traditional.GitStatus.TuiState
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  describe "git_status_changed" do
    test "with open git panel updates panel data and returns render" do
      state = base_state()

      state =
        EditorState.set_git_status_panel(state, %{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      event =
        {:minga_event, :git_status_changed,
         %Minga.Events.GitStatusEvent{
           git_root: "/tmp/repo",
           entries: [%{path: "foo.ex", status: :modified}],
           branch: "develop",
           ahead: 1,
           behind: 0
         }}

      {new_state, effects} = FileEventHandler.handle(state, event)

      panel = EditorState.git_status_panel(new_state)
      assert panel.branch == "develop"
      assert panel.ahead == 1
      assert {:render, 16} in effects
    end

    test "does not create tui state during generic panel refresh" do
      state =
        base_state()
        |> EditorState.set_git_status_panel(%{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      event =
        {:minga_event, :git_status_changed,
         %Minga.Events.GitStatusEvent{
           git_root: "/tmp/repo",
           entries: [%StatusEntry{path: "foo.ex", status: :modified, staged: false}],
           branch: "develop",
           ahead: 1,
           behind: 0
         }}

      {new_state, _effects} = FileEventHandler.handle(state, event)

      panel = EditorState.git_status_panel(new_state)
      refute Map.has_key?(panel, :tui_state)
      assert ShellState.git_status_tui_state(new_state.shell_state) == nil
    end

    test "refreshes existing tui state through the shell state boundary" do
      entries = [%StatusEntry{path: "old.ex", status: :modified, staged: false}]

      state =
        base_state()
        |> EditorState.set_git_status_panel(%{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: entries
        })
        |> EditorState.update_shell_state(
          &ShellState.set_git_status_tui_state(&1, %{TuiState.new() | cursor_index: 99})
        )

      refreshed_entries = [%StatusEntry{path: "new.ex", status: :modified, staged: false}]

      event =
        {:minga_event, :git_status_changed,
         %Minga.Events.GitStatusEvent{
           git_root: "/tmp/repo",
           entries: refreshed_entries,
           branch: "develop",
           ahead: 1,
           behind: 0
         }}

      {new_state, _effects} = FileEventHandler.handle(state, event)

      assert EditorState.git_status_panel(new_state).entries == refreshed_entries
      assert %TuiState{cursor_index: 1} = ShellState.git_status_tui_state(new_state.shell_state)
      refute Map.has_key?(EditorState.git_status_panel(new_state), :tui_state)
    end

    test "without git panel open is a no-op" do
      state = base_state()

      event =
        {:minga_event, :git_status_changed,
         %Minga.Events.GitStatusEvent{
           git_root: "/tmp/repo",
           entries: [],
           branch: "main",
           ahead: 0,
           behind: 0
         }}

      {new_state, effects} = FileEventHandler.handle(state, event)
      assert new_state == state
      assert effects == []
    end
  end

  describe "buffer_saved" do
    test "returns code_lens and inlay_hints effects" do
      state = base_state()

      event =
        {:minga_event, :buffer_saved,
         %Minga.Events.BufferEvent{buffer: self(), path: "/tmp/test.ex"}}

      {_state, effects} = FileEventHandler.handle(state, event)

      assert {:request_code_lens} in effects
      assert {:request_inlay_hints} in effects
    end

    test "returns save_session_deferred in non-headless mode" do
      state = base_state()
      state = %{state | backend: :tui}

      event =
        {:minga_event, :buffer_saved,
         %Minga.Events.BufferEvent{buffer: self(), path: "/tmp/test.ex"}}

      {_state, effects} = FileEventHandler.handle(state, event)

      assert {:save_session_deferred} in effects
    end

    test "does not return save_session_deferred in headless mode" do
      state = base_state()

      event =
        {:minga_event, :buffer_saved,
         %Minga.Events.BufferEvent{buffer: self(), path: "/tmp/test.ex"}}

      {_state, effects} = FileEventHandler.handle(state, event)

      refute {:save_session_deferred} in effects
    end
  end

  describe "git_remote_result" do
    test "returns handle_git_remote_result effect" do
      state = base_state()
      ref = make_ref()
      event = {:git_remote_result, ref, :ok}

      {_state, effects} = FileEventHandler.handle(state, event)

      assert {:handle_git_remote_result, ^ref, :ok} =
               Enum.find(effects, &match?({:handle_git_remote_result, _, _}, &1))
    end
  end

  describe "catch-all" do
    test "unknown messages return no-op" do
      state = base_state()
      {new_state, effects} = FileEventHandler.handle(state, :unknown_file_event)
      assert new_state == state
      assert effects == []
    end
  end
end
