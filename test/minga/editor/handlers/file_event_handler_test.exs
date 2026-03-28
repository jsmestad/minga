defmodule Minga.Editor.Handlers.FileEventHandlerTest do
  @moduledoc """
  Pure-function tests for `Minga.Editor.Handlers.FileEventHandler`.

  Uses `RenderPipeline.TestHelpers.base_state/1` to construct state
  without starting a GenServer.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.Handlers.FileEventHandler
  alias Minga.Editor.State, as: EditorState

  import Minga.Editor.RenderPipeline.TestHelpers

  describe "git_status_changed" do
    test "with open git panel updates panel data and returns render" do
      state = base_state()
      # Open the git status panel
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
      # base_state defaults to headless
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
