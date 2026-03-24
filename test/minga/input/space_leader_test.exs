defmodule Minga.Input.SpaceLeaderTest do
  @moduledoc """
  Tests for the SPC-as-leader feature in CUA mode.

  Tests the SpaceLeader input handler which intercepts SPC in CUA mode
  to enable hold-SPC-as-leader for the which-key command layer.
  """

  # async: false because we mutate global Config.Options (editing_model, space_leader)
  use Minga.Test.EditorCase, async: false

  alias Minga.Config.Options

  setup do
    # Enable CUA mode with space leader for these tests
    Options.set(:editing_model, :cua)
    Options.set(:space_leader, :chord)
    Options.set(:space_leader_timeout, 200)

    on_exit(fn ->
      Options.set(:editing_model, :vim)
      Options.set(:space_leader, :chord)
    end)

    :ok
  end

  describe "SPC inserts space and sets pending" do
    test "typing SPC inserts a space and marks pending" do
      ctx = start_editor("hello")
      send_key(ctx, 0x20)

      state = editor_state(ctx)
      assert state.space_leader_pending == true
    end
  end

  describe "leader key after SPC" do
    test "leader-matching key retracts space and enters leader mode" do
      ctx = start_editor("hello")

      # SPC inserts space and sets pending
      send_key(ctx, 0x20)
      assert editor_state(ctx).space_leader_pending == true

      # 'f' is a leader trie prefix (SPC f = +file group)
      send_key(ctx, ?f)

      state = editor_state(ctx)
      # Leader mode should be active (whichkey node is set)
      assert state.whichkey.node != nil
      # Pending should be cleared
      assert state.space_leader_pending == false
    end
  end

  describe "non-leader key after SPC" do
    test "non-matching key clears pending and passes through" do
      ctx = start_editor("")

      send_key(ctx, 0x20)
      assert editor_state(ctx).space_leader_pending == true

      # '!' is not a leader prefix
      send_key(ctx, ?!)

      state = editor_state(ctx)
      assert state.space_leader_pending == false
    end
  end

  describe "timer expiration" do
    test "timer clears pending state" do
      ctx = start_editor("hello")

      send_key(ctx, 0x20)
      state = editor_state(ctx)
      assert state.space_leader_pending == true
      assert state.space_leader_timer != nil

      # Trigger the timer directly
      trigger_space_leader_timeout(ctx)

      state = editor_state(ctx)
      assert state.space_leader_pending == false
    end
  end

  describe "modified SPC passes through" do
    test "Shift+SPC does not set pending" do
      ctx = start_editor("hello")
      send_key(ctx, 0x20, 1)

      assert editor_state(ctx).space_leader_pending == false
    end

    test "Ctrl+SPC does not set pending" do
      ctx = start_editor("hello")
      send_key(ctx, 0x20, 4)

      assert editor_state(ctx).space_leader_pending == false
    end
  end

  describe "inactive in vim mode" do
    test "SPC does not set pending when editing_model is :vim" do
      Options.set(:editing_model, :vim)
      ctx = start_editor("hello")
      send_key(ctx, 0x20)

      assert editor_state(ctx).space_leader_pending == false
    end
  end

  describe "inactive when space_leader is :off" do
    test "SPC does not set pending when space_leader is :off" do
      Options.set(:space_leader, :off)
      ctx = start_editor("hello")
      send_key(ctx, 0x20)

      assert editor_state(ctx).space_leader_pending == false
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp trigger_space_leader_timeout(%{editor: editor}) do
    state = :sys.get_state(editor)

    case state.space_leader_timer do
      ref when is_reference(ref) ->
        Process.cancel_timer(ref)
        send(editor, {:space_leader_timeout, ref})
        _ = :sys.get_state(editor)

      _ ->
        :ok
    end
  end
end
