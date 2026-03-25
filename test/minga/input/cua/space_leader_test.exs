defmodule Minga.Input.CUA.SpaceLeaderTest do
  @moduledoc """
  Tests for the SPC-as-leader key-chord feature in CUA mode.

  The Swift frontend detects key-chord gestures (SPC held + another key)
  and sends gui_actions. These tests simulate those gui_actions and verify
  the BEAM-side behavior: leader trie lookup, space retraction, and
  leader mode entry.
  """

  # async: false because we mutate global Config.Options (editing_model, space_leader)
  use Minga.Test.EditorCase, async: false

  alias Minga.Config.Options
  alias Minga.Input.CUA.SpaceLeader

  setup do
    Options.set(:editing_model, :cua)
    Options.set(:space_leader, :chord)

    on_exit(fn ->
      Options.set(:editing_model, :vim)
      Options.set(:space_leader, :chord)
    end)

    :ok
  end

  describe "handle_chord (clean chord, no space sent)" do
    test "leader-matching key enters leader mode" do
      ctx = start_editor("hello")

      # Simulate Swift sending space_leader_chord with 'f' key
      # (SPC f = +file group in default keymap)
      send(ctx.editor, {:minga_input, {:gui_action, {:space_leader_chord, ?f, 0}}})
      _ = :sys.get_state(ctx.editor)

      state = editor_state(ctx)
      # Leader mode should be active
      assert state.whichkey.node != nil
      # Buffer should NOT have a space (clean chord)
      refute String.contains?(buffer_content(ctx), " ")
    end

    test "non-matching key inserts space and types the key" do
      ctx = start_editor("")

      # '!' is not a leader trie prefix
      send(ctx.editor, {:minga_input, {:gui_action, {:space_leader_chord, ?!, 0}}})
      _ = :sys.get_state(ctx.editor)

      # Space should be inserted (the withheld space) plus the key
      content = buffer_content(ctx)
      assert String.contains?(content, " ")
    end
  end

  describe "handle_retract (fallback chord, space already sent)" do
    test "leader-matching key retracts space and enters leader mode" do
      ctx = start_editor("hello")

      # First: simulate the space being sent (grace timer fired on Swift side)
      send_key(ctx, 0x20)

      # Then: Swift detects the chord and sends retract
      send(ctx.editor, {:minga_input, {:gui_action, {:space_leader_retract, ?f, 0}}})
      _ = :sys.get_state(ctx.editor)

      state = editor_state(ctx)
      assert state.whichkey.node != nil
      # The space should have been retracted
      refute String.ends_with?(buffer_content(ctx), " f")
    end

    test "non-matching key leaves space, types key normally" do
      ctx = start_editor("")

      # Space was sent
      send_key(ctx, 0x20)

      # Non-leader key: space stays, key passes through
      send(ctx.editor, {:minga_input, {:gui_action, {:space_leader_retract, ?!, 0}}})
      _ = :sys.get_state(ctx.editor)

      content = buffer_content(ctx)
      assert String.contains?(content, " ")
    end
  end

  describe "active? guard" do
    test "inactive when editing_model is :vim" do
      Options.set(:editing_model, :vim)
      refute SpaceLeader.active?()
    end

    test "inactive when space_leader is :off" do
      Options.set(:space_leader, :off)
      refute SpaceLeader.active?()
    end

    test "active when CUA mode and chord enabled" do
      assert SpaceLeader.active?()
    end
  end

  describe "keystroke replay when inactive" do
    test "chord replays withheld space and dispatches key in vim insert mode" do
      Options.set(:editing_model, :vim)
      ctx = start_editor("")

      # Enter insert mode
      send_key(ctx, ?i)

      # Simulate Swift sending space_leader_chord with 'w' key.
      # This happens when the user types " w" fast enough that 'w'
      # arrives within the 30ms grace window.
      send(ctx.editor, {:minga_input, {:gui_action, {:space_leader_chord, ?w, 0}}})
      _ = :sys.get_state(ctx.editor)

      state = editor_state(ctx)
      # Should NOT enter leader mode
      assert state.whichkey.node == nil
      # Both the withheld space AND the 'w' must appear in the buffer
      assert buffer_content(ctx) == " w"
    end

    test "retract dispatches key normally in vim insert mode" do
      Options.set(:editing_model, :vim)
      ctx = start_editor("")

      # Enter insert mode
      send_key(ctx, ?i)

      # Space was already sent (grace timer fired)
      send_key(ctx, 0x20)

      # Swift detects late chord, sends retract
      send(ctx.editor, {:minga_input, {:gui_action, {:space_leader_retract, ?w, 0}}})
      _ = :sys.get_state(ctx.editor)

      state = editor_state(ctx)
      assert state.whichkey.node == nil
      # Space was already in buffer, 'w' must also appear
      assert buffer_content(ctx) == " w"
    end

    test "chord replays space and key in CUA mode without :chord enabled" do
      Options.set(:editing_model, :cua)
      Options.set(:space_leader, :off)
      ctx = start_editor("")

      send(ctx.editor, {:minga_input, {:gui_action, {:space_leader_chord, ?x, 0}}})
      _ = :sys.get_state(ctx.editor)

      # Both space and key should appear
      content = buffer_content(ctx)
      assert String.contains?(content, " ")
      assert String.contains?(content, "x")
    end
  end
end
