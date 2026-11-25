defmodule MingaEditor.Handlers.SessionHandlerTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Handlers.SessionHandler`.

  Uses `RenderPipeline.TestHelpers.base_state/1` to construct state
  without starting a GenServer.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Handlers.SessionHandler
  alias MingaEditor.State.Frontend
  alias MingaEditor.State.Session, as: SessionState

  import MingaEditor.RenderPipeline.TestHelpers

  describe "save_session" do
    test "saves into the project's own session file" do
      state = base_state() |> in_project("/tmp/project")
      state = %{state | session: SessionState.new(session_dir: "/tmp/test_session")}

      {_new_state, effects} = SessionHandler.handle(state, :save_session)

      assert [{:save_session_async, %{project_root: "/tmp/project"}, opts}] =
               Enum.filter(effects, &match?({:save_session_async, _, _}, &1))

      assert opts[:session_dir] == "/tmp/test_session"
      assert opts[:project_root] == "/tmp/project"
    end

    test "outside a project there is no session to save" do
      state = %{base_state() | session: SessionState.new(session_dir: "/tmp/test_session")}

      {_new_state, effects} = SessionHandler.handle(state, :save_session)

      refute Enum.any?(effects, &match?({:save_session_async, _, _}, &1))
    end

    test "returns restart_session_timer in non-headless mode" do
      state = base_state()
      %Frontend{} = current_frontend = state.frontend
      frontend = %Frontend{current_frontend | backend: :tui}
      state = %{state | frontend: frontend, session: SessionState.new(session_dir: "/tmp/test")}

      {_state, effects} = SessionHandler.handle(state, :save_session)

      assert {:restart_session_timer} in effects
      refute {:cancel_session_timer} in effects
    end

    test "returns cancel_session_timer in headless mode" do
      state = base_state()
      state = %{state | session: SessionState.new(session_dir: "/tmp/test")}

      {_state, effects} = SessionHandler.handle(state, :save_session)

      assert {:cancel_session_timer} in effects
      refute {:restart_session_timer} in effects
    end
  end

  describe "check_swap_recovery" do
    test "headless mode never scans swap files" do
      state = base_state()

      state = %{
        state
        | session: SessionState.new(swap_dir: "/tmp/swaps", session_dir: "/tmp/session")
      }

      {new_state, effects} = SessionHandler.handle(state, :check_swap_recovery)
      assert new_state == state
      assert effects == []
    end

    test "non-headless mode emits immutable recovery input without reading files" do
      state = base_state()
      %Frontend{} = current_frontend = state.frontend
      frontend = %Frontend{current_frontend | backend: :tui}

      state =
        %{
          state
          | frontend: frontend,
            session: SessionState.new(swap_dir: "/missing/swaps", session_dir: "/missing/session")
        }

      assert {^state,
              [
                {:recover_session_async, [swap_dir: "/missing/swaps"],
                 [project_root: nil, session_dir: "/missing/session"], true, false}
              ]} = SessionHandler.handle(state, :check_swap_recovery)
    end

    test "an empty workspace in a project restores its session, headless too" do
      state =
        base_state()
        |> in_project("/tmp/project")
        |> without_buffers()
        |> Map.put(:session, SessionState.new(session_dir: "/missing/session"))

      assert {^state,
              [
                {:recover_session_async, _swap,
                 [project_root: "/tmp/project", session_dir: "/missing/session"], false, true}
              ]} = SessionHandler.handle(state, :check_swap_recovery)
    end

    test "a workspace that already shows a file keeps it instead of restoring" do
      state =
        base_state()
        |> in_project("/tmp/project")
        |> Map.put(:session, SessionState.new(session_dir: "/missing/session"))

      refute SessionHandler.restore_enabled?(state)
    end
  end

  defp in_project(state, root) do
    tree = %MingaEditor.State.FileTree{project_root: root}
    %{state | workspace: MingaEditor.Session.State.set_file_tree(state.workspace, tree)}
  end

  defp without_buffers(state) do
    buffers = %MingaEditor.State.Buffers{active: nil, list: [], active_index: 0}
    %{state | workspace: MingaEditor.Session.State.set_buffers(state.workspace, buffers)}
  end

  describe "catch-all" do
    test "unknown messages return no-op" do
      state = base_state()
      {new_state, effects} = SessionHandler.handle(state, :unknown_session_msg)
      assert new_state == state
      assert effects == []
    end
  end
end
