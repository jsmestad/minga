defmodule MingaEditor.InlineAsk.RenderIntegrationTest do
  use Minga.Test.EditorCase, async: true

  @moduletag :tmp_dir

  test "inline ask decorations render through the editor scroll/content pipeline", %{tmp_dir: dir} do
    path = Path.join(dir, "lib/demo.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "alpha\nbeta")

    ctx = start_editor("alpha\nbeta", file_path: path, project_root: dir)
    send_keys_sync(ctx, "<SPC>a?")
    sync_screen(ctx)

    assert Enum.any?(screen_text(ctx), &String.contains?(&1, "Ask about line 1 of demo.ex"))
    assert Enum.any?(screen_text(ctx), &String.contains?(&1, "? █"))

    send_keys_sync(ctx, "why")
    sync_screen(ctx)

    assert Enum.any?(screen_text(ctx), &String.contains?(&1, "? why█"))
  end
end
