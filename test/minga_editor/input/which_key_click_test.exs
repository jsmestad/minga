defmodule MingaEditor.Input.WhichKeyClickTest do
  @moduledoc """
  A click in the editor abandons a pending leader sequence, so the next key is never read inside the abandoned group.

  The click is applied inside the Editor process through `MingaEditor.Mouse.handle_text_event/3`, the handler behind the `editor_text_event` ingress, because the headless port has no text interaction index to resolve presented rows.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaEditor.Mouse
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Shell.Runtime

  @moduletag :tmp_dir

  test "in Vim, SPC then a click then w moves a word and leaves the leader closed" do
    ctx = start_editor("one two three")
    send_keys_sync(ctx, "<SPC>")
    assert leader_open?(ctx)

    click_at(ctx, {0, 0})
    send_keys_sync(ctx, "w")

    assert buffer_cursor(ctx) == {0, 4}
    refute leader_open?(ctx)
    refute Minga.Editing.in_leader?(editor_state(ctx))
  end

  test "in CUA, a SPC f chord then a click then f types the f and opens no picker", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "focus.txt")
    File.write!(path, "focus")
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))

    ctx =
      start_editor("focus",
        file_path: path,
        project_root: dir,
        editing_model: :cua,
        options_server: options
      )

    send_gui_action(ctx, {:space_leader_chord, ?f, 0})
    assert leader_open?(ctx)

    click_at(ctx, {0, 0})
    send_keys_sync(ctx, "f")

    refute picker_open?(ctx)
    refute leader_open?(ctx)
    assert buffer_content(ctx) == "ffocus"
  end

  defp leader_open?(ctx), do: Runtime.state(editor_state(ctx).shell_runtime).whichkey.node != nil

  defp click_at(ctx, {line, byte}) do
    :sys.replace_state(ctx.editor, fn state ->
      window_id = state.workspace.windows.active
      buffer = state.workspace.buffers.active

      target =
        TextTarget.new(%{
          window_id: window_id,
          buffer: buffer,
          source_version: Minga.Buffer.version(buffer),
          line: line,
          byte: byte
        })

      state
      |> Mouse.handle_text_event(text_event(window_id, :press), target)
      |> Mouse.handle_text_event(text_event(window_id, :release), nil)
    end)
  end

  defp text_event(window_id, event_type) do
    TextEvent.new(%{
      window_id: window_id,
      presentation_id: 11,
      row_index: 0,
      row_id: 22,
      utf16_offset: 0,
      button: :left,
      mods: 0,
      event_type: event_type,
      click_count: 1,
      scroll_x: 0,
      scroll_y: 0
    })
  end
end
