defmodule Minga.Editing.CommentTest do
  @moduledoc "Tests for pure comment toggling logic."

  use ExUnit.Case, async: true

  alias Minga.Editing.Comment

  # ── comment_prefix/1 ───────────────────────────────────────────────────────

  describe "comment_prefix/1" do
    test "returns the token when given a string" do
      assert Comment.comment_prefix("// ") == "// "
      assert Comment.comment_prefix("# ") == "# "
      assert Comment.comment_prefix("-- ") == "-- "
    end

    test "returns # as fallback when nil" do
      assert Comment.comment_prefix(nil) == "# "
    end
  end

  # ── comment_prefix_at/4 ───────────────────────────────────────────────────

  describe "comment_prefix_at/4" do
    defp stub_token_resolver(:javascript), do: "// "
    defp stub_token_resolver(:html), do: "<!-- "
    defp stub_token_resolver(:elixir), do: "# "
    defp stub_token_resolver(_), do: nil

    test "returns default token comment when no injection ranges" do
      assert Comment.comment_prefix_at("# ", 50, [], &stub_token_resolver/1) == "# "
    end

    test "returns injection language comment when inside an injection range" do
      ranges = [
        %{start_byte: 100, end_byte: 200, language: "javascript"}
      ]

      assert Comment.comment_prefix_at("<!-- ", 150, ranges, &stub_token_resolver/1) == "// "
    end

    test "returns default token when outside injection ranges" do
      ranges = [
        %{start_byte: 100, end_byte: 200, language: "javascript"}
      ]

      assert Comment.comment_prefix_at("<!-- ", 50, ranges, &stub_token_resolver/1) == "<!-- "
    end

    test "falls back to default for unknown injection language" do
      ranges = [
        %{start_byte: 0, end_byte: 100, language: "nonexistent_language_xyz"}
      ]

      assert Comment.comment_prefix_at("# ", 50, ranges, &stub_token_resolver/1) == "# "
    end
  end

  # ── compute_toggle_edits/3 ─────────────────────────────────────────────────

  describe "compute_toggle_edits/3" do
    test "comments a single uncommented line" do
      edits = Comment.compute_toggle_edits(["hello"], "# ", 0)
      assert edits == [{:insert, 0, 0, "# "}]
    end

    test "uncomments a single commented line" do
      edits = Comment.compute_toggle_edits(["# hello"], "# ", 0)
      assert edits == [{:delete, 0, 0, 2}]
    end

    test "comments multiple lines" do
      edits = Comment.compute_toggle_edits(["hello", "world"], "# ", 0)
      assert edits == [{:insert, 1, 0, "# "}, {:insert, 0, 0, "# "}]
    end

    test "uncomments all when all are commented" do
      edits = Comment.compute_toggle_edits(["# hello", "# world"], "# ", 0)
      assert edits == [{:delete, 1, 0, 2}, {:delete, 0, 0, 2}]
    end

    test "comments all when mixed commented/uncommented" do
      edits = Comment.compute_toggle_edits(["# hello", "world"], "# ", 0)
      assert edits == [{:insert, 1, 0, "# "}, {:insert, 0, 0, "# "}]
    end

    test "skips empty lines" do
      edits = Comment.compute_toggle_edits(["hello", "", "world"], "# ", 0)
      assert edits == [{:insert, 2, 0, "# "}, {:insert, 0, 0, "# "}]
    end

    test "preserves indentation by commenting at min indent level" do
      edits = Comment.compute_toggle_edits(["  hello", "    world", "  foo"], "# ", 0)
      # Min indent is 2, so inserts go at col 2
      assert edits == [{:insert, 2, 2, "# "}, {:insert, 1, 2, "# "}, {:insert, 0, 2, "# "}]
    end

    test "uncomments with indentation" do
      edits = Comment.compute_toggle_edits(["  # hello", "  # world"], "# ", 0)
      assert edits == [{:delete, 1, 2, 2}, {:delete, 0, 2, 2}]
    end

    test "returns empty list for all empty lines" do
      assert Comment.compute_toggle_edits(["", ""], "# ", 0) == []
    end

    test "uses correct start_line offset" do
      edits = Comment.compute_toggle_edits(["hello"], "# ", 5)
      assert edits == [{:insert, 5, 0, "# "}]
    end

    test "works with // comment prefix" do
      edits = Comment.compute_toggle_edits(["const x = 5;"], "// ", 0)
      assert edits == [{:insert, 0, 0, "// "}]
    end

    test "works with -- comment prefix" do
      edits = Comment.compute_toggle_edits(["local x = 5"], "-- ", 0)
      assert edits == [{:insert, 0, 0, "-- "}]
    end
  end
end
