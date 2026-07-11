defmodule MingaEditor.HighlightIntegrationTest do
  @moduledoc """
  Thin editor-level smoke coverage for syntax-highlight lifecycle wiring.

  Detailed span behavior and state transitions live in the lower-layer
  highlight suites.
  """

  use Minga.Test.EditorCase, async: true

  alias MingaEditor.HighlightSync

  @tag :tmp_dir
  test "switching buffers clears and restores cached highlights", %{tmp_dir: dir} do
    first_path = Path.join(dir, "first.ex")
    second_path = Path.join(dir, "second.ex")
    File.write!(first_path, "defmodule A do\nend\n")
    File.write!(second_path, "defmodule B do\nend\n")

    ctx = start_editor("defmodule A do\nend\n", file_path: first_path)
    spans = [%{start_byte: 0, end_byte: 9, capture_id: 0}]
    inject_highlights(ctx, ["keyword"], 1, spans)

    state = send_ex_sync(ctx, "e #{second_path}")
    assert HighlightSync.get_active_highlight(state).spans == {}

    state = send_ex_sync(ctx, "e #{first_path}")
    assert HighlightSync.get_active_highlight(state).spans == List.to_tuple(spans)
  end
end
