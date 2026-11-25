defmodule MingaEditor.Input.WhichKeyTimingTest do
  @moduledoc """
  Which-key opens only after a pause (docs/design/surfaces.md): typing straight through a leader sequence never shows it, because each key starts a new reveal generation and a reveal for an older one is ignored.

  The suite runs with the reveal timer off (`whichkey_timeout_ms: :infinity` in config/test.exs), so the tests deliver the timer message themselves, the way `Process.send_after/3` would.
  """

  use Minga.Test.EditorCase, async: true

  alias MingaEditor.Shell.Runtime

  defp whichkey(ctx), do: Runtime.state(editor_state(ctx).shell_runtime).whichkey

  defp fire_reveal(ctx, generation) do
    send(ctx.editor, {:whichkey_reveal, generation})
    _ = editor_state(ctx)
    whichkey(ctx).show
  end

  test "typing SPC f f straight through never shows which-key, even when an older timer fires late" do
    ctx = start_editor("hello")

    send_keys_sync(ctx, "<SPC>")
    after_spc = whichkey(ctx).generation
    send_keys_sync(ctx, "f")
    after_f = whichkey(ctx).generation

    refute fire_reveal(ctx, after_spc), "the SPC timer is stale once f is typed"

    send_keys_sync(ctx, "f")
    assert picker_open?(ctx)
    refute fire_reveal(ctx, after_f), "the sequence is over; its timer shows nothing"
  end

  test "a pause shows which-key for the group the sequence reached" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "<SPC>a")

    assert fire_reveal(ctx, whichkey(ctx).generation)
    assert MingaEditor.State.WhichKey.path(whichkey(ctx)) == "SPC a"
  end

  test "pausing on a Normal prefix shows its keys without taking ownership from Vim" do
    ctx = start_editor("first\nsecond\nthird")

    for prefix <- ["g", "z", "[", "]"] do
      send_keys_sync(ctx, prefix)
      refute whichkey(ctx).show
      generation = whichkey(ctx).generation
      assert fire_reveal(ctx, generation)
      assert MingaEditor.State.WhichKey.path(whichkey(ctx)) == prefix
      send_keys_sync(ctx, "<Esc>")
      refute fire_reveal(ctx, generation)
    end

    send_keys_sync(ctx, "Gg")
    assert fire_reveal(ctx, whichkey(ctx).generation)
    send_gui_action(ctx, {:which_key_press, "g", ?g, 0})
    assert buffer_cursor(ctx) == {0, 0}
    refute whichkey(ctx).show
  end

  test "typing gg through does not paint which-key, even when the reveal arrives late" do
    ctx = start_editor("first\nsecond\nthird")
    send_keys_sync(ctx, "Gg")
    generation = whichkey(ctx).generation

    send_keys_sync(ctx, "g")
    assert buffer_cursor(ctx) == {0, 0}
    refute fire_reveal(ctx, generation)
  end

  test "gc dismisses the Normal prefix even when it enters a different mode" do
    for reveal_before_command? <- [false, true] do
      ctx = start_editor("first\nsecond")
      send_keys_sync(ctx, "g")
      generation = whichkey(ctx).generation

      if reveal_before_command?,
        do: assert(fire_reveal(ctx, generation)),
        else: refute(whichkey(ctx).show)

      send_keys_sync(ctx, "c")
      assert editor_mode(ctx) == :operator_pending
      refute whichkey(ctx).show
      refute fire_reveal(ctx, generation), "a finished prefix cannot reveal over the operator"
    end
  end
end
