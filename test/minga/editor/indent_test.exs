defmodule Minga.Editor.IndentTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Indent

  describe "compute_for_newline/2" do
    test "copies indentation from previous line" do
      buf = start_buffer("  hello\n  world")
      assert Indent.compute_for_newline(buf, 0) == "  "
      assert Indent.compute_for_newline(buf, 1) == "  "
    end

    test "no indentation on unindented line" do
      buf = start_buffer("hello\nworld")
      assert Indent.compute_for_newline(buf, 0) == ""
    end

    test "indents after Elixir do block" do
      buf = start_buffer("  def foo do\n    bar\n  end", filetype: :elixir)
      indent = Indent.compute_for_newline(buf, 0)
      assert indent == "    "
    end

    test "indents after opening brace" do
      buf = start_buffer("  fn main() {", filetype: :rust)
      indent = Indent.compute_for_newline(buf, 0)
      assert indent == "    "
    end

    test "indents after opening bracket" do
      buf = start_buffer("  items = [", filetype: :elixir)
      indent = Indent.compute_for_newline(buf, 0)
      assert indent == "    "
    end

    test "indents after Python colon" do
      buf = start_buffer("  def foo():", filetype: :python)
      indent = Indent.compute_for_newline(buf, 0)
      assert indent == "    "
    end

    test "indents after Elixir arrow" do
      buf = start_buffer("  fn x ->", filetype: :elixir)
      indent = Indent.compute_for_newline(buf, 0)
      assert indent == "    "
    end

    test "preserves tab indentation" do
      buf = start_buffer("\thello", filetype: :c)
      indent = Indent.compute_for_newline(buf, 0)
      assert indent == "\t"
    end

    test "returns empty for out-of-range line" do
      buf = start_buffer("hello")
      assert Indent.compute_for_newline(buf, 99) == ""
    end

    test "handles empty buffer" do
      buf = start_buffer("")
      assert Indent.compute_for_newline(buf, 0) == ""
    end
  end

  describe "should_dedent_line?/2" do
    test "detects Elixir end keyword" do
      buf = start_buffer("  end", filetype: :elixir)
      assert Indent.should_dedent_line?(buf, 0)
    end

    test "detects closing brace" do
      buf = start_buffer("  }", filetype: :rust)
      assert Indent.should_dedent_line?(buf, 0)
    end

    test "does not dedent normal line" do
      buf = start_buffer("  hello", filetype: :elixir)
      refute Indent.should_dedent_line?(buf, 0)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp start_buffer(content, opts \\ []) do
    filetype = Keyword.get(opts, :filetype)
    init_opts = [content: content] ++ if(filetype, do: [filetype: filetype], else: [])
    {:ok, buf} = BufferServer.start_link(init_opts)
    buf
  end
end
