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
end
