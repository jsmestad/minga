defmodule MingaEditor.Integration.MatchItemTest do
  # Uses the global ParserManager because commands request match items through the production parser.
  use Minga.Test.EditorCase, async: false

  setup do
    if Process.whereis(Minga.Parser.Manager) == nil do
      start_supervised!({Minga.Parser.Manager, []})
    end

    :ok
  end

  describe "% match item motion" do
    test "jumps from Elixir def to matching end" do
      content = "def foo do\n  :ok\nend\n"
      ctx = start_editor(content, file_path: tmp_file("match_item.ex", content))
      assert Minga.Buffer.Process.filetype(ctx.buffer) == :elixir
      wait_for_highlight(ctx)

      send_keys_sync(ctx, "%")

      assert buffer_cursor(ctx) == {2, 0}
    end

    test "jumps between string delimiters" do
      content = "message = \"hello\"\n"
      ctx = start_editor(content, file_path: tmp_file("match_item.js", content))
      wait_for_highlight(ctx)
      assert editor_mode(ctx) == :normal
      assert buffer_content(ctx) == content
      send_keys_sync(ctx, "llllllllll")
      assert buffer_cursor(ctx) == {0, 10}

      send_keys_sync(ctx, "%")

      assert buffer_cursor(ctx) == {0, 16}
    end

    test "delete operator with match item deletes through keyword" do
      content = "def foo do\n  :ok\nend\n"
      ctx = start_editor(content, file_path: tmp_file("match_item_delete.ex", content))
      wait_for_highlight(ctx)

      send_keys_sync(ctx, "d%")

      assert buffer_content(ctx) == "\n"
    end

    test "delete operator with reverse match item deletes the full keyword range" do
      content = "def foo do\n  :ok\nend\n"
      ctx = start_editor(content, file_path: tmp_file("match_item_reverse_delete.ex", content))
      wait_for_highlight(ctx)

      send_keys_sync(ctx, "%d%")

      assert buffer_content(ctx) == "\n"
    end

    test "delete operator with no match is a no-op" do
      content = "word\n"
      ctx = start_editor(content, file_path: tmp_file("match_item_no_match.txt", content))

      send_keys_sync(ctx, "d%")

      assert buffer_content(ctx) == content
      assert buffer_cursor(ctx) == {0, 0}
    end

    test "comment operator with match item comments the matched keyword range" do
      content = "def foo do\n  :ok\nend\n"
      ctx = start_editor(content, file_path: tmp_file("match_item_comment.ex", content))
      wait_for_highlight(ctx)

      send_keys_sync(ctx, "gc%")

      assert buffer_content(ctx) == "# def foo do\n#   :ok\n# end\n"
    end

    test "delete operator with tag match item deletes the full tag name token" do
      content = "<h1>x</h1>\n"
      ctx = start_editor(content, file_path: tmp_file("match_item_tag_delete.html", content))
      wait_for_highlight(ctx)

      send_keys_sync(ctx, "ld%")

      assert buffer_content(ctx) == "<>\n"
    end

    test "visual match item extends selection cursor to match" do
      content = "def foo do\n  :ok\nend\n"
      ctx = start_editor(content, file_path: tmp_file("match_item_visual.ex", content))
      wait_for_highlight(ctx)

      send_keys_sync(ctx, "v%")

      assert editor_mode(ctx) == :visual
      assert buffer_cursor(ctx) == {2, 0}
    end

    test "plain text without a grammar is a no-op" do
      content = "(hello)\n"
      ctx = start_editor(content, file_path: tmp_file("match_item.txt", content))

      send_keys_sync(ctx, "%")

      assert buffer_cursor(ctx) == {0, 0}
    end
  end

  defp wait_for_highlight(ctx) do
    wait_until(
      ctx,
      fn state ->
        highlight = MingaEditor.HighlightSync.get_active_highlight(state)
        is_tuple(highlight.spans) and tuple_size(highlight.spans) > 0
      end,
      max_attempts: 100,
      interval_ms: 20
    )
  end

  defp tmp_file(name, content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "minga_match_item_#{System.unique_integer([:positive])}_#{name}"
      )

    File.write!(path, content)
    path
  end
end
