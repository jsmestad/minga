defmodule MingaEditor.Input.CUA.TUISpaceLeaderTest do
  @moduledoc """
  Tests for BEAM-side SPC-as-leader for TUI frontends in CUA mode.

  Unlike the GUI SpaceLeader (which receives gui_actions from Swift),
  the TUI version uses a timer-based approach: SPC inserts a space
  immediately, starts a timeout, and retracts the space if a leader
  key arrives within the window.

  Bug 3 regression: SPC leader must work on TUI, not just GUI.
  """

  # async: false because we mutate global Config.Options (space_leader)
  use Minga.Test.EditorCase, async: false

  alias Minga.Config.Options
  alias MingaEditor.Input.CUA.TUISpaceLeader

  setup do
    Options.set(:space_leader, :chord)

    on_exit(fn ->
      Options.set(:space_leader, :chord)
    end)

    :ok
  end

  describe "SPC + leader key activates leader mode" do
    test "SPC then 'f' within timeout enters leader mode and retracts space" do
      # Start with TUI backend so TUISpaceLeader is active
      ctx = start_editor("hello", editing_model: :cua, backend: :tui)

      # Send SPC (inserts space, starts timer)
      send_key_sync(ctx, 0x20)

      state = editor_state(ctx)
      assert state.space_leader_pending == true

      # Send 'f' (leader prefix for +file)
      send_key_sync(ctx, ?f)

      state = editor_state(ctx)
      # Leader mode should be active
      assert state.shell_state.whichkey.node != nil
      # Space should have been retracted
      assert state.space_leader_pending == false
      refute String.ends_with?(buffer_content(ctx), " ")
    end
  end

  describe "SPC timeout commits the space" do
    test "timeout clears pending state without affecting buffer" do
      ctx = start_editor("", editing_model: :cua, backend: :tui)

      # Send SPC
      send_key_sync(ctx, 0x20)

      state = editor_state(ctx)
      assert state.space_leader_pending == true

      # Send timeout directly (per AGENTS.md: send timer messages directly)
      send(ctx.editor, :space_leader_timeout)
      _ = :sys.get_state(ctx.editor)

      state = editor_state(ctx)
      assert state.space_leader_pending == false
      # Space should remain in buffer
      assert buffer_content(ctx) == " "
    end
  end

  describe "SPC + non-leader key passes through" do
    test "SPC then '!' inserts space and passes key through" do
      ctx = start_editor("", editing_model: :cua, backend: :tui)

      # Send SPC then '!' (not a leader prefix)
      send_key_sync(ctx, 0x20)
      send_key_sync(ctx, ?!)

      state = editor_state(ctx)
      assert state.space_leader_pending == false
      # Space stays in buffer, '!' passes through to CUA.Dispatch
      assert String.starts_with?(buffer_content(ctx), " ")
    end
  end

  describe "inactive guards" do
    test "inactive in vim mode" do
      refute TUISpaceLeader.active?(%{editing_model: :vim, backend: :tui})
    end

    test "inactive when space_leader is :off" do
      Options.set(:space_leader, :off)
      refute TUISpaceLeader.active?(%{editing_model: :cua, backend: :tui})
    end

    test "inactive on GUI backend" do
      # GUI uses Swift-side chord detection, not the BEAM timer
      refute TUISpaceLeader.active?(%{editing_model: :cua, backend: :native_gui})
    end

    test "active on TUI with CUA and chord enabled" do
      assert TUISpaceLeader.active?(%{editing_model: :cua, backend: :tui})
    end

    test "SPC passes through when inactive (vim mode)" do
      ctx = start_editor("", editing_model: :vim, backend: :tui)

      # In vim normal mode, SPC is the leader key (handled by ModeFSM)
      # TUISpaceLeader should passthrough
      send_key_sync(ctx, 0x20)

      state = editor_state(ctx)
      assert state.space_leader_pending == false
    end
  end
end
