defmodule MingaEditor.Handlers.SessionHandlerTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Handlers.SessionHandler`.

  Uses `RenderPipeline.TestHelpers.base_state/1` to construct state
  without starting a GenServer.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Handlers.SessionHandler
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
      state = %{state | backend: :tui, session: SessionState.new(session_dir: "/tmp/test")}

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
    test "with no recoverable swaps and clean shutdown is a no-op" do
      # When swap_dir is nil, scan_recoverable_swaps returns []
      # and clean_shutdown? with nil session_dir returns true (no session file = clean)
      state = base_state()
      state = %{state | session: SessionState.new(swap_dir: nil, session_dir: nil)}

      {new_state, effects} = SessionHandler.handle(state, :check_swap_recovery)
      assert new_state == state
      assert effects == []
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
