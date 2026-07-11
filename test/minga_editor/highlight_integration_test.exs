defmodule MingaEditor.HighlightIntegrationTest do
  @moduledoc """
  Thin integration coverage for syntax highlighting lifecycle.

  Detailed span math lives in `test/minga_editor/ui/highlight_test.exs`, and pure highlight state transitions live in `test/minga_editor/highlight_sync_test.exs`. This file keeps only editor-level smoke coverage for switching buffers with highlights active.
  """

  use Minga.Test.EditorCase, async: true

  alias MingaEditor.HighlightSync

  describe "buffer switch highlight lifecycle" do
    @tag :tmp_dir
    test "opening a new file clears stale active highlights", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "file1.txt")
      path2 = Path.join(tmp_dir, "file2.txt")
      File.write!(path1, "defmodule A do\nend\n")
      File.write!(path2, "defmodule B do\nend\n")

      ctx = start_editor("defmodule A do\nend\n", file_path: path1)
      inject_highlights(ctx, ["keyword"], 1, [%{start_byte: 0, end_byte: 9, capture_id: 0}])

      state = send_ex_sync(ctx, "e #{path2}")

      assert HighlightSync.get_active_highlight(state).spans == {}
    end

    @tag :tmp_dir
    test "switching back to a highlighted file restores its cached spans", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "file1.txt")
      path2 = Path.join(tmp_dir, "file2.txt")
      File.write!(path1, "defmodule A do\nend\n")
      File.write!(path2, "defmodule B do\nend\n")

      ctx = start_editor("defmodule A do\nend\n", file_path: path1)
      spans = [%{start_byte: 0, end_byte: 9, capture_id: 0}]
      inject_highlights(ctx, ["keyword"], 1, spans)

      send_ex_sync(ctx, "e #{path2}")
      state = send_ex_sync(ctx, "e #{path1}")

      assert HighlightSync.get_active_highlight(state).spans == List.to_tuple(spans)
    end
  end

  describe "highlighted editor smoke checks" do
    test "normal-mode edits remain usable while highlights are active" do
      ctx = start_editor("line one\nline two\nline three")
      inject_highlights(ctx, ["keyword"], 1, [%{start_byte: 0, end_byte: 4, capture_id: 0}])

      send_keys_sync(ctx, "dd")

      assert buffer_content(ctx) == "line two\nline three"
    end
  end
end
