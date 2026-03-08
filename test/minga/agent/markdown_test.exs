defmodule Minga.Agent.MarkdownTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Markdown

  describe "parse/1" do
    test "parses plain text" do
      result = Markdown.parse("Hello world")
      assert [{[{"Hello world", :plain}], :text}] = result
    end

    test "parses empty string" do
      result = Markdown.parse("")
      assert [{[{"", :plain}], :empty}] = result
    end

    test "parses bold text with **" do
      result = Markdown.parse("Hello **world**")
      assert [{segments, :text}] = result
      assert [{"Hello ", :plain}, {"world", :bold}] = segments
    end

    test "parses bold text with __" do
      result = Markdown.parse("Hello __world__")
      assert [{segments, :text}] = result
      assert [{"Hello ", :plain}, {"world", :bold}] = segments
    end

    test "parses italic text with *" do
      result = Markdown.parse("Hello *world*")
      assert [{segments, :text}] = result
      assert [{"Hello ", :plain}, {"world", :italic}] = segments
    end

    test "parses inline code" do
      result = Markdown.parse("Use `mix compile` here")
      assert [{segments, :text}] = result
      assert [{"Use ", :plain}, {"mix compile", :code}, {" here", :plain}] = segments
    end

    test "parses H1 header" do
      result = Markdown.parse("# Title")
      assert [{[{"Title", :header1}], :header}] = result
    end

    test "parses H2 header" do
      result = Markdown.parse("## Subtitle")
      assert [{[{"Subtitle", :header2}], :header}] = result
    end

    test "parses H3 header" do
      result = Markdown.parse("### Section")
      assert [{[{"Section", :header3}], :header}] = result
    end

    test "parses unordered list items with -" do
      result = Markdown.parse("- First item")
      assert [{segments, :list_item}] = result
      assert [{"  • First item", :plain}] = segments
    end

    test "parses unordered list items with *" do
      result = Markdown.parse("* Second item")
      assert [{segments, :list_item}] = result
      assert [{"  • Second item", :plain}] = segments
    end

    test "parses blockquotes" do
      result = Markdown.parse("> Some quote")
      assert [{_segments, :blockquote}] = result
    end

    test "parses horizontal rules" do
      for rule <- ["---", "***", "___"] do
        result = Markdown.parse(rule)
        assert [{[{_, :rule}], :rule}] = result
      end
    end

    test "parses fenced code blocks" do
      text = """
      ```elixir
      def hello, do: :world
      ```\
      """

      result = Markdown.parse(text)

      assert [
               {[{"┌─ elixir ", :code_block}, {"─", :code_block}], :code},
               {[{"│ def hello, do: :world", :code_block}], :code},
               {[{"└", :code_block}, {"─", :code_block}], :code}
             ] = result
    end

    test "parses code blocks without language tag" do
      text = """
      ```
      some code
      ```\
      """

      result = Markdown.parse(text)

      assert [
               {[{"┌─ code ", :code_block}, {"─", :code_block}], :code},
               {[{"│ some code", :code_block}], :code},
               {[{"└", :code_block}, {"─", :code_block}], :code}
             ] = result
    end

    test "handles unclosed code block gracefully" do
      text = "```elixir\ndef hello, do: :world"
      result = Markdown.parse(text)
      # Should not crash, just treat remaining lines as code
      assert length(result) == 2
    end

    test "parses multiple paragraphs" do
      text = "First line\n\nSecond line"
      result = Markdown.parse(text)
      assert length(result) == 3
    end

    test "handles mixed formatting in one line" do
      result = Markdown.parse("This is **bold** and *italic* and `code`")
      assert [{segments, :text}] = result

      assert [
               {"This is ", :plain},
               {"bold", :bold},
               {" and ", :plain},
               {"italic", :italic},
               {" and ", :plain},
               {"code", :code}
             ] = segments
    end

    test "handles unclosed bold gracefully" do
      result = Markdown.parse("Hello **world")
      assert [{segments, :text}] = result
      # Should not crash; the plain regex consumes the whole string
      assert [{"Hello **world", :plain}] = segments
    end

    test "handles unclosed inline code gracefully" do
      result = Markdown.parse("Hello `world")
      assert [{segments, :text}] = result
      # Should not crash; the plain regex consumes the whole string
      assert [{"Hello `world", :plain}] = segments
    end
  end

  describe "parse_inline/1" do
    test "returns plain for empty string" do
      assert [] = Markdown.parse_inline("")
    end

    test "merges adjacent plain segments" do
      result = Markdown.parse_inline("hello world")
      assert [{"hello world", :plain}] = result
    end

    test "handles emoji and unicode" do
      result = Markdown.parse_inline("Hello 🌍 world")
      assert [{"Hello 🌍 world", :plain}] = result
    end
  end

  describe "extract_code_blocks/1" do
    test "extracts a single code block" do
      md = """
      Some text before.

      ```elixir
      def hello, do: :world
      ```

      Some text after.
      """

      blocks = Markdown.extract_code_blocks(md)
      assert [%{language: "elixir", content: "def hello, do: :world"}] = blocks
    end

    test "extracts multiple code blocks" do
      md = """
      First block:

      ```python
      print("hello")
      ```

      Second block:

      ```bash
      echo hi
      ```
      """

      blocks = Markdown.extract_code_blocks(md)
      assert length(blocks) == 2
      assert Enum.at(blocks, 0).language == "python"
      assert Enum.at(blocks, 0).content == "print(\"hello\")"
      assert Enum.at(blocks, 1).language == "bash"
      assert Enum.at(blocks, 1).content == "echo hi"
    end

    test "handles code block without language" do
      md = "```\nsome code\n```"
      blocks = Markdown.extract_code_blocks(md)
      assert [%{language: "", content: "some code"}] = blocks
    end

    test "returns empty list when no code blocks" do
      assert Markdown.extract_code_blocks("just text") == []
    end

    test "handles multi-line code blocks" do
      md = "```ruby\nline1\nline2\nline3\n```"
      blocks = Markdown.extract_code_blocks(md)
      assert [%{content: "line1\nline2\nline3"}] = blocks
    end

    test "handles unclosed code block" do
      md = "```\nunclosed content"
      assert Markdown.extract_code_blocks(md) == []
    end
  end
end
