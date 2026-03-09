defmodule Minga.Agent.CodeHighlightTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.CodeHighlight

  describe "supported?/1" do
    test "returns true for supported languages" do
      for lang <- [
            "elixir",
            "javascript",
            "python",
            "rust",
            "go",
            "zig",
            "bash",
            "ruby",
            "typescript",
            "html",
            "css",
            "sql",
            "json",
            "yaml",
            "lua",
            "c",
            "cpp"
          ] do
        assert CodeHighlight.supported?(lang), "expected #{lang} to be supported"
      end
    end

    test "returns true for language aliases" do
      for {alias_name, _canonical} <- [
            {"js", "javascript"},
            {"ts", "typescript"},
            {"sh", "bash"},
            {"py", "python"},
            {"rb", "ruby"},
            {"rs", "rust"},
            {"ex", "elixir"},
            {"exs", "elixir"},
            {"yml", "yaml"},
            {"jsx", "javascript"},
            {"tsx", "typescript"}
          ] do
        assert CodeHighlight.supported?(alias_name),
               "expected alias #{alias_name} to be supported"
      end
    end

    test "returns false for unsupported languages" do
      refute CodeHighlight.supported?("brainfuck")
      refute CodeHighlight.supported?("")
    end
  end

  describe "highlight_line/2 - Elixir" do
    test "highlights keywords" do
      segments = CodeHighlight.highlight_line("def hello do", "elixir")
      assert has_capture?(segments, "def", "keyword")
      assert has_capture?(segments, "do", "keyword")
    end

    test "highlights strings" do
      segments = CodeHighlight.highlight_line("x = \"hello world\"", "elixir")
      assert has_capture?(segments, "\"hello world\"", "string")
    end

    test "highlights comments" do
      segments = CodeHighlight.highlight_line("# this is a comment", "elixir")
      assert has_capture?(segments, "# this is a comment", "comment")
    end

    test "highlights module names as types" do
      segments = CodeHighlight.highlight_line("alias MyApp.Module", "elixir")
      assert has_capture?(segments, "MyApp.Module", "type")
    end

    test "highlights atoms" do
      segments = CodeHighlight.highlight_line("status = :ok", "elixir")
      assert has_capture?(segments, ":ok", "string.special.symbol")
    end

    test "highlights numbers" do
      segments = CodeHighlight.highlight_line("x = 42", "elixir")
      assert has_capture?(segments, "42", "number")
    end

    test "highlights function calls" do
      segments = CodeHighlight.highlight_line("  length(str)", "elixir")
      assert has_capture?(segments, "length", "function.call")
    end

    test "highlights pipe operator" do
      segments = CodeHighlight.highlight_line("x |> map()", "elixir")
      assert has_capture?(segments, "|>", "operator")
    end

    test "highlights hex numbers" do
      segments = CodeHighlight.highlight_line("color = 0xFF00FF", "elixir")
      assert has_capture?(segments, "0xFF00FF", "number")
    end
  end

  describe "highlight_line/2 - JavaScript" do
    test "highlights keywords" do
      segments = CodeHighlight.highlight_line("const x = 42;", "javascript")
      assert has_capture?(segments, "const", "keyword")
    end

    test "highlights strings" do
      segments = CodeHighlight.highlight_line("let s = \"hello\"", "js")
      assert has_capture?(segments, "\"hello\"", "string")
    end

    test "highlights comments" do
      segments = CodeHighlight.highlight_line("// comment here", "javascript")
      assert has_capture?(segments, "// comment here", "comment")
    end

    test "highlights template literals" do
      segments = CodeHighlight.highlight_line("let s = `hello`", "javascript")
      assert has_capture?(segments, "`hello`", "string")
    end
  end

  describe "highlight_line/2 - Python" do
    test "highlights keywords" do
      segments = CodeHighlight.highlight_line("def hello():", "python")
      assert has_capture?(segments, "def", "keyword")
    end

    test "highlights decorators" do
      segments = CodeHighlight.highlight_line("@property", "python")
      assert has_capture?(segments, "@property", "function.macro")
    end

    test "highlights f-strings" do
      segments = CodeHighlight.highlight_line("x = f\"hello {name}\"", "python")
      assert has_capture?(segments, "f\"hello {name}\"", "string.special")
    end
  end

  describe "highlight_line/2 - Rust" do
    test "highlights keywords" do
      segments = CodeHighlight.highlight_line("fn main() {", "rust")
      assert has_capture?(segments, "fn", "keyword")
    end

    test "highlights types" do
      segments = CodeHighlight.highlight_line("let x: Vec<String> = vec![];", "rust")
      assert has_capture?(segments, "Vec", "type.builtin")
    end

    test "highlights macro invocations" do
      segments = CodeHighlight.highlight_line("println!(\"hello\")", "rust")
      assert has_capture?(segments, "println!", "function.macro")
    end
  end

  describe "highlight_line/2 - Bash" do
    test "highlights variables" do
      segments = CodeHighlight.highlight_line("echo $HOME", "bash")
      assert has_capture?(segments, "$HOME", "variable.builtin")
    end

    test "highlights builtins" do
      segments = CodeHighlight.highlight_line("echo hello", "bash")
      assert has_capture?(segments, "echo", "function.builtin")
    end
  end

  describe "highlight_line/2 - JSON" do
    test "highlights keys differently from values" do
      segments = CodeHighlight.highlight_line(~s(  "name": "value"), "json")
      assert has_capture?(segments, ~s("name"), "string.special.key")
      assert has_capture?(segments, ~s("value"), "string")
    end

    test "highlights booleans and null" do
      segments = CodeHighlight.highlight_line("  \"flag\": true", "json")
      assert has_capture?(segments, "true", "keyword")
    end
  end

  describe "highlight_line/2 - SQL" do
    test "highlights keywords case-insensitively" do
      segments = CodeHighlight.highlight_line("SELECT * FROM users", "sql")
      assert has_capture?(segments, "SELECT", "keyword")
      assert has_capture?(segments, "FROM", "keyword")
    end
  end

  describe "highlight_line/2 - unsupported language" do
    test "returns plain text for unknown language" do
      segments = CodeHighlight.highlight_line("some code here", "brainfuck")
      assert [{"some code here", ""}] = segments
    end
  end

  describe "highlight_line/2 - edge cases" do
    test "handles empty line" do
      assert [] = CodeHighlight.highlight_line("", "elixir")
    end

    test "handles line with only whitespace" do
      segments = CodeHighlight.highlight_line("   ", "elixir")
      assert [{"   ", ""}] = segments
    end

    test "handles unicode in strings" do
      segments = CodeHighlight.highlight_line("x = \"hello 🌍\"", "elixir")
      assert has_capture?(segments, "\"hello 🌍\"", "string")
    end
  end

  # ── Helper ──────────────────────────────────────────────────────────────

  defp has_capture?(segments, text, capture) do
    Enum.any?(segments, fn {t, c} -> t == text and c == capture end)
  end
end
