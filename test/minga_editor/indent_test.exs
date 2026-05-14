defmodule MingaEditor.IndentTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor.Indent

  describe "compute_for_line/3" do
    test "converts tree-sitter indent levels to spaces" do
      buf = start_buffer("def foo do\nbar\nend", filetype: :elixir)
      request_indent = fn 42, 1 -> 2 end

      indent = Indent.compute_for_line(buf, 1, buffer_id: 42, request_indent: request_indent)

      assert indent == "    "
    end

    test "converts tree-sitter indent levels to tabs" do
      buf = start_buffer("fn main() {\nbody\n}", filetype: :rust)
      {:ok, :tabs} = BufferServer.set_option(buf, :indent_with, :tabs)
      request_indent = fn 42, 1 -> 2 end

      indent = Indent.compute_for_line(buf, 1, buffer_id: 42, request_indent: request_indent)

      assert indent == "\t\t"
    end

    test "falls back to previous line copy-indent when parser indentation is unavailable" do
      buf = start_buffer("  parent\nchild")

      assert Indent.compute_for_line(buf, 1) == "  "
    end

    test "falls back to empty indentation for the first line" do
      buf = start_buffer("  child")

      assert Indent.compute_for_line(buf, 0) == ""
    end

    test "uses explicit fallback when provided" do
      buf = start_buffer("  child")

      assert Indent.compute_for_line(buf, 0, fallback: "  ") == "  "
    end

    test "falls back when parser returns nil" do
      buf = start_buffer("  parent\nchild")
      request_indent = fn 42, 1 -> nil end

      indent = Indent.compute_for_line(buf, 1, buffer_id: 42, request_indent: request_indent)

      assert indent == "  "
    end

    test "falls back when parser exits" do
      buf = start_buffer("  parent\nchild")
      request_indent = fn 42, 1 -> exit(:noproc) end

      indent = Indent.compute_for_line(buf, 1, buffer_id: 42, request_indent: request_indent)

      assert indent == "  "
    end

    test "falls back when parser returns a negative level" do
      buf = start_buffer("  parent\nchild")
      request_indent = fn 42, 1 -> -1 end

      indent = Indent.compute_for_line(buf, 1, buffer_id: 42, request_indent: request_indent)

      assert indent == "  "
    end

    test "returns empty for out-of-range line" do
      buf = start_buffer("hello")
      assert Indent.compute_for_line(buf, 99) == ""
    end

    test "handles empty buffer" do
      buf = start_buffer("")
      assert Indent.compute_for_line(buf, 0) == ""
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
