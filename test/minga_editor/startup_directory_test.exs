defmodule MingaEditor.StartupDirectoryTest do
  @moduledoc """
  `minga <dir>` at a subdirectory of a project opens the project (its root is the nearest marker above) with the file finder already narrowed to that subdirectory (#4057, #4056 AC3). Retired startup choices are named in `*Messages*`.
  """

  use Minga.Test.EditorCase, async: true

  alias MingaEditor.Startup

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    File.mkdir_p!(Path.join(root, "lib/agent"))
    File.write!(Path.join(root, "mix.exs"), "defmodule P.MixProject do\nend\n")
    File.write!(Path.join(root, "lib/agent/session.ex"), "session\n")
    %{root: root}
  end

  test "a subdirectory start opens the file finder narrowed to that subdirectory", ctx do
    editor =
      start_editor("",
        empty: true,
        project_root: ctx.root,
        startup_directory: Path.join(ctx.root, "lib/agent"),
        rendering: :disabled
      )

    assert picker_state(editor).query == "lib/agent/"
  end

  test "the project root itself opens no finder", ctx do
    editor =
      start_editor("",
        empty: true,
        project_root: ctx.root,
        startup_directory: ctx.root,
        rendering: :disabled
      )

    assert picker_state(editor) == nil
  end

  test "retired startup choices each get one line in *Messages*" do
    assert [editor_note, context_note, view_note] =
             Startup.retired_startup_notes(["--editor", "--no-context"], :agent)

    assert editor_note =~ "--editor is no longer needed"
    assert context_note =~ "--no-context is no longer needed"
    assert view_note =~ ":startup_view no longer changes where Minga starts"
    assert Startup.retired_startup_notes([], :editor) == []
  end
end
