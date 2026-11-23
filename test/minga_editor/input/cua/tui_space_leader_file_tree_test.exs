defmodule MingaEditor.Input.CUA.TUISpaceLeaderFileTreeTest do
  @moduledoc """
  SPC on a focused file tree in CUA mode on the terminal frontend starts the leader and never edits the file buffer (#3961).

  The file tree is not a text input, so it never gets the space-then-retract window that `CUA.TUISpaceLeader` gives the file buffer. A lone SPC must not leave a space in the file even when no leader key follows.
  """

  # The terminal backend never acknowledges a headless frame, so these editors
  # run without rendering and focus the tree with the command in the Editor process.
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Config.Options
  alias MingaEditor.Commands
  alias MingaEditor.FocusOwner

  @moduletag :tmp_dir

  test "a lone SPC on the focused tree starts the leader and leaves the file unchanged", %{
    tmp_dir: dir
  } do
    ctx = focused_tree_editor(dir)

    send_keys_sync(ctx, "<SPC>")

    assert Minga.Editing.in_leader?(editor_state(ctx))
    assert buffer_content(ctx) == "focus"
  end

  test "SPC f f on the focused tree opens find-file without typing into the file", %{
    tmp_dir: dir
  } do
    ctx = focused_tree_editor(dir)

    send_keys_sync(ctx, "<SPC>ff")

    assert picker_open?(ctx)
    assert buffer_content(ctx) == "focus"
  end

  defp focused_tree_editor(dir) do
    path = Path.join(dir, "focus.txt")
    File.write!(path, "focus")
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))

    ctx =
      start_editor("focus",
        file_path: path,
        project_root: dir,
        editing_model: :cua,
        backend: :tui,
        options_server: options
      )

    :sys.replace_state(ctx.editor, &Commands.execute(&1, :toggle_file_tree))
    assert %{surface: :file_tree} = FocusOwner.derive(editor_state(ctx))
    ctx
  end
end
