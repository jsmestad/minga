defmodule MingaEditor.Input.WhichKeyCUATest do
  @moduledoc """
  The CUA space leader names its own prefix, so which-key shows the group's sections and counts and Backspace goes back up, the same as in Vim.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaEditor.RenderModel.UI.WhichKeyBuilder
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State.WhichKey

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "cua.txt")
    File.write!(path, "text")
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))

    ctx =
      start_editor("text",
        file_path: path,
        project_root: dir,
        editing_model: :cua,
        options_server: options
      )

    %{ctx: ctx}
  end

  test "a SPC a chord opens SPC › a Minga with its sections; Backspace goes up to SPC, then closes",
       %{ctx: ctx} do
    send_gui_action(ctx, {:space_leader_chord, ?a, 0})

    whichkey = whichkey(ctx)
    assert whichkey.prefix_keys == ["SPC", "a"]
    assert whichkey.labels == ["Leader", "Minga"]

    model = WhichKeyBuilder.build(%{whichkey | show: true})
    assert model.path == "SPC a"

    assert model.entries |> Enum.map(& &1.section) |> Enum.dedup() ==
             ["Tasks", "Conversation", "Changes", "More"]

    send_keys_sync(ctx, "<BS>")
    assert whichkey(ctx).prefix_keys == ["SPC"]
    assert buffer_content(ctx) == "text"

    send_keys_sync(ctx, "<BS>")
    assert whichkey(ctx).node == nil
    assert buffer_content(ctx) == "text"
  end

  test "over a picker, a typed key and Backspace edit the query and close the picker's keys", %{
    ctx: ctx
  } do
    send_gui_action(ctx, {:execute_command, "find_file"})
    assert picker_open?(ctx)

    send_gui_action(ctx, {:execute_command, "which_key_open"})
    assert WhichKey.path(whichkey(ctx)) == "Picker"
    send_keys_sync(ctx, "x")
    assert whichkey(ctx).node == nil
    assert String.ends_with?(picker_state(ctx).query, "x")

    send_gui_action(ctx, {:execute_command, "which_key_open"})
    send_keys_sync(ctx, "<BS>")
    assert whichkey(ctx).node == nil
    assert picker_open?(ctx)
    refute String.ends_with?(picker_state(ctx).query, "x")
  end

  test "over a picker, ↩ reaches the picker and opens the selection", %{ctx: ctx, tmp_dir: dir} do
    other_path = Path.join(dir, "other.txt")
    File.write!(other_path, "other")
    :ok = MingaEditor.open_file(ctx.editor, other_path)
    assert active_content(ctx) == "other"

    send_gui_action(ctx, {:execute_command, "buffer_list"})
    send_keys_sync(ctx, "cua.txt")
    send_gui_action(ctx, {:execute_command, "which_key_open"})
    assert WhichKey.path(whichkey(ctx)) == "Picker"

    send_keys_sync(ctx, "<CR>")

    assert whichkey(ctx).node == nil
    refute picker_open?(ctx)
    assert active_content(ctx) == "text"
  end

  defp whichkey(ctx), do: Runtime.state(editor_state(ctx).shell_runtime).whichkey
end
