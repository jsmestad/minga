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
    test "returns save_session_async effect with snapshot and opts" do
      state = base_state()
      session = SessionState.new(session_dir: "/tmp/test_session")
      state = %{state | session: session}

      {_new_state, effects} = SessionHandler.handle(state, :save_session)

      assert Enum.any?(effects, fn
               {:save_session_async, _snapshot, opts} -> opts[:session_dir] == "/tmp/test_session"
               _ -> false
             end)
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
    test "headless mode does not initiate startup recovery" do
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
                 [session_dir: "/missing/session"], true, true}
              ]} = SessionHandler.handle(state, :check_swap_recovery)
    end
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
