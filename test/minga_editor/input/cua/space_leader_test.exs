defmodule MingaEditor.Input.CUA.SpaceLeaderTest do
  @moduledoc """
  Smoke tests for SPC-as-leader key chords in CUA mode.
  """

  # async: false because this file mutates global Config.Options (:space_leader).
  use Minga.Test.EditorCase, async: false

  alias Minga.Config.Options
  alias MingaEditor.Input.CUA.SpaceLeader

  setup do
    Options.set(:space_leader, :chord)

    on_exit(fn ->
      Options.set(:space_leader, :chord)
    end)

    :ok
  end

  describe "CUA chord handling" do
    test "leader-matching clean chord enters leader mode without inserting a space" do
      ctx = start_editor("hello", editing_model: :cua)

      state = send_space_leader_chord(ctx, ?f)

      assert state.shell_state.whichkey.node != nil
      refute String.contains?(buffer_content(ctx), " ")
    end

    test "non-matching clean chord inserts the withheld space and key" do
      ctx = start_editor("", editing_model: :cua)

      send_space_leader_chord(ctx, ?!)

      assert String.contains?(buffer_content(ctx), " ")
      assert String.contains?(buffer_content(ctx), "!")
    end

    test "leader-matching retract removes the already-inserted space" do
      ctx = start_editor("hello", editing_model: :cua)
      send_key_sync(ctx, 0x20)

      state = send_space_leader_retract(ctx, ?f)

      assert state.shell_state.whichkey.node != nil
      refute String.ends_with?(buffer_content(ctx), " f")
    end
  end

  describe "inactive behavior" do
    test "active? follows editing model and option state" do
      refute SpaceLeader.active?(%{editing_model: :vim})

      Options.set(:space_leader, :off)
      refute SpaceLeader.active?(%{editing_model: :cua})

      Options.set(:space_leader, :chord)
      assert SpaceLeader.active?(%{editing_model: :cua})
    end

    test "inactive chord replays the withheld space and key" do
      ctx = start_editor("", editing_model: :vim)
      send_key_sync(ctx, ?i)

      state = send_space_leader_chord(ctx, ?w)

      assert state.shell_state.whichkey.node == nil
      assert buffer_content(ctx) == " w"
    end

    test "disabled CUA chord replays the withheld space and key" do
      Options.set(:space_leader, :off)
      ctx = start_editor("", editing_model: :cua)

      send_space_leader_chord(ctx, ?x)

      assert String.contains?(buffer_content(ctx), " ")
      assert String.contains?(buffer_content(ctx), "x")
    end
  end

  defp send_space_leader_chord(ctx, key) do
    send(ctx.editor, {:minga_input, {:gui_action, {:space_leader_chord, key, 0}}})
    editor_state(ctx)
  end

  defp send_space_leader_retract(ctx, key) do
    send(ctx.editor, {:minga_input, {:gui_action, {:space_leader_retract, key, 0}}})
    editor_state(ctx)
  end
end
