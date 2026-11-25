defmodule MingaEditor.Input.WhichKeyCUATest do
  @moduledoc """
  The CUA space leader names its own prefix, so which-key shows the group's sections and counts and Backspace goes back up, the same as in Vim.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaEditor.RenderModel.UI.WhichKeyBuilder
  alias MingaEditor.Shell.Runtime

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

  defp whichkey(ctx), do: Runtime.state(editor_state(ctx).shell_runtime).whichkey
end
