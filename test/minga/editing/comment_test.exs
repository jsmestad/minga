defmodule Minga.Editing.CommentTest do
  @moduledoc "Tests for line comment toggling."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editing.Comment

  # ── comment_string/1 ───────────────────────────────────────────────────────

  describe "comment_string/1" do
    test "returns # for Elixir" do
      assert Comment.comment_string(:elixir) == "# "
    end

    test "returns // for Zig" do
      assert Comment.comment_string(:zig) == "// "
    end

    test "returns // for JavaScript" do
      assert Comment.comment_string(:javascript) == "// "
    end

    test "returns -- for Lua" do
      assert Comment.comment_string(:lua) == "-- "
    end

    test "returns ;; for Emacs Lisp" do
      assert Comment.comment_string(:emacs_lisp) == ";; "
    end

    test "returns % for Erlang" do
      assert Comment.comment_string(:erlang) == "% "
    end

    test "returns # for unknown filetypes" do
      assert Comment.comment_string(:some_unknown_lang) == "# "
    end

    test "returns // for all C-family languages" do
      for lang <- [:c, :cpp, :go, :rust, :java, :kotlin, :swift, :c_sharp, :dart, :php] do
        assert Comment.comment_string(lang) == "// ", "Expected // for #{lang}"
      end
    end

    test "returns # for scripting languages" do
      for lang <- [:python, :ruby, :bash, :fish] do
        assert Comment.comment_string(lang) == "# ", "Expected # for #{lang}"
      end
    end
  end

  # ── comment_string_at/3 ───────────────────────────────────────────────────

  describe "comment_string_at/3" do
    test "returns buffer filetype comment when no injection ranges" do
      assert Comment.comment_string_at(:elixir, 50, []) == "# "
    end

    test "returns injection language comment when inside an injection range" do
      ranges = [
        %{start_byte: 100, end_byte: 200, language: "javascript"}
      ]

      assert Comment.comment_string_at(:html, 150, ranges) == "// "
    end

    test "returns buffer filetype comment when outside injection ranges" do
      ranges = [
        %{start_byte: 100, end_byte: 200, language: "javascript"}
      ]

      assert Comment.comment_string_at(:html, 50, ranges) == "<!-- "
    end

    test "falls back to filetype for unknown injection language" do
      ranges = [
        %{start_byte: 0, end_byte: 100, language: "nonexistent_language_xyz"}
      ]

      # Should not crash, falls back to filetype
      assert Comment.comment_string_at(:elixir, 50, ranges) == "# "
    end
  end

  # ── toggle_lines/5 with buffer ─────────────────────────────────────────────

  describe "toggle_lines/5" do
    setup do
      {:ok, buf} =
        DynamicSupervisor.start_child(
          Minga.Buffer.Supervisor,
          {BufferServer, content: "hello\nworld\nfoo"}
        )

      %{buf: buf}
    end

    test "comments a single uncommented line", %{buf: buf} do
      Comment.toggle_lines(buf, 0, 0, :elixir)
      {content, _} = BufferServer.content_and_cursor(buf)
      [first | _] = String.split(content, "\n")
      assert first == "# hello"
    end

    test "uncomments a single commented line", %{buf: buf} do
      BufferServer.replace_content(buf, "# hello\nworld\nfoo")
      Comment.toggle_lines(buf, 0, 0, :elixir)
      {content, _} = BufferServer.content_and_cursor(buf)
      [first | _] = String.split(content, "\n")
      assert first == "hello"
    end

    test "comments multiple lines", %{buf: buf} do
      Comment.toggle_lines(buf, 0, 1, :elixir)
      {content, _} = BufferServer.content_and_cursor(buf)
      lines = String.split(content, "\n")
      assert Enum.at(lines, 0) == "# hello"
      assert Enum.at(lines, 1) == "# world"
      assert Enum.at(lines, 2) == "foo"
    end

    test "uncomments all lines when all are commented", %{buf: buf} do
      BufferServer.replace_content(buf, "# hello\n# world\nfoo")
      Comment.toggle_lines(buf, 0, 1, :elixir)
      {content, _} = BufferServer.content_and_cursor(buf)
      lines = String.split(content, "\n")
      assert Enum.at(lines, 0) == "hello"
      assert Enum.at(lines, 1) == "world"
    end

    test "comments all when mixed commented/uncommented", %{buf: buf} do
      BufferServer.replace_content(buf, "# hello\nworld\nfoo")
      Comment.toggle_lines(buf, 0, 1, :elixir)
      {content, _} = BufferServer.content_and_cursor(buf)
      lines = String.split(content, "\n")
      assert Enum.at(lines, 0) == "# # hello"
      assert Enum.at(lines, 1) == "# world"
    end

    test "skips empty lines", %{buf: buf} do
      BufferServer.replace_content(buf, "hello\n\nworld")
      Comment.toggle_lines(buf, 0, 2, :elixir)
      {content, _} = BufferServer.content_and_cursor(buf)
      lines = String.split(content, "\n")
      assert Enum.at(lines, 0) == "# hello"
      assert Enum.at(lines, 1) == ""
      assert Enum.at(lines, 2) == "# world"
    end

    test "preserves indentation", %{buf: buf} do
      BufferServer.replace_content(buf, "  hello\n    world\n  foo")
      Comment.toggle_lines(buf, 0, 2, :elixir)
      {content, _} = BufferServer.content_and_cursor(buf)
      lines = String.split(content, "\n")
      # Min indent is 2, so comment prefix goes at col 2
      # Lines with more indent keep their extra whitespace after the prefix
      assert Enum.at(lines, 0) == "  # hello"
      assert Enum.at(lines, 1) == "  #   world"
      assert Enum.at(lines, 2) == "  # foo"
    end

    test "uncomments with indentation", %{buf: buf} do
      BufferServer.replace_content(buf, "  # hello\n  # world")
      Comment.toggle_lines(buf, 0, 1, :elixir)
      {content, _} = BufferServer.content_and_cursor(buf)
      lines = String.split(content, "\n")
      assert Enum.at(lines, 0) == "  hello"
      assert Enum.at(lines, 1) == "  world"
    end

    test "uses // for Zig filetype", %{buf: buf} do
      BufferServer.replace_content(buf, "const x = 5;")
      Comment.toggle_lines(buf, 0, 0, :zig)
      {content, _} = BufferServer.content_and_cursor(buf)
      [first | _] = String.split(content, "\n")
      assert first == "// const x = 5;"
    end

    test "uses -- for Lua filetype", %{buf: buf} do
      BufferServer.replace_content(buf, "local x = 5")
      Comment.toggle_lines(buf, 0, 0, :lua)
      {content, _} = BufferServer.content_and_cursor(buf)
      [first | _] = String.split(content, "\n")
      assert first == "-- local x = 5"
    end

    test "no-op on all empty lines", %{buf: buf} do
      BufferServer.replace_content(buf, "\n\n")
      Comment.toggle_lines(buf, 0, 1, :elixir)
      {content, _} = BufferServer.content_and_cursor(buf)
      assert content == "\n\n"
    end
  end
end
