defmodule Minga.LSP.HoverContentTest do
  use ExUnit.Case, async: true

  alias Minga.LSP.HoverContent

  describe "markdown/1" do
    test "trims markup content and strings without altering Markdown" do
      for {contents, expected} <- [
            {%{"kind" => "markdown", "value" => " # Hello\n\nWorld "}, "# Hello\n\nWorld"},
            {%{"kind" => "plaintext", "value" => " simple text "}, "simple text"},
            {"  hello  ", "hello"}
          ] do
        assert HoverContent.markdown(contents) == expected
      end
    end

    test "accepts unknown kinds and gives kind precedence over language" do
      contents = %{"kind" => "unknown", "language" => "elixir", "value" => " **text** "}
      assert HoverContent.markdown(contents) == "**text**"
    end

    test "fences language-tagged snippets, including empty snippets" do
      contents = %{"language" => "elixir", "value" => " @spec foo() :: :ok "}
      assert HoverContent.markdown(contents) == "```elixir\n@spec foo() :: :ok\n```"
      assert HoverContent.markdown(%{"language" => 42, "value" => " \n"}) == "```42\n\n```"
    end

    test "joins nested contents in order and skips only empty decoded text" do
      contents = [
        %{"kind" => "markdown", "value" => "Part 1"},
        [nil, " ", %{"kind" => "markdown", "value" => "Part 2"}],
        %{"language" => "elixir", "value" => ""},
        "Part 3"
      ]

      assert HoverContent.markdown(contents) == "Part 1\n\nPart 2\n\n```elixir\n\n```\n\nPart 3"
    end

    test "returns empty text when nothing can be decoded" do
      for contents <- [nil, %{}, %{"kind" => "markdown", "value" => 1}, [[], " ", nil]] do
        assert HoverContent.markdown(contents) == ""
      end
    end
  end
end
