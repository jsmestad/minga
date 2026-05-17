defmodule MingaEditor.UI.HighlightScopeTest do
  use ExUnit.Case, async: true

  alias Minga.Language.Highlight.Span
  alias MingaEditor.UI.Highlight

  describe "scope_at/2" do
    test "empty highlight data returns code" do
      assert Highlight.scope_at(Highlight.new(), 0) == :code
    end

    test "classifies string and comment captures" do
      highlight =
        Highlight.new()
        |> Highlight.put_names(["string", "comment", "keyword"])
        |> Highlight.put_spans(1, [
          Span.new(4, 12, 0),
          Span.new(20, 30, 1),
          Span.new(0, 3, 2)
        ])

      prefix = String.duplicate("x", 20)

      assert Highlight.scope_at(highlight, 5) == :string
      assert Highlight.scope_at(highlight, 25) == :comment
      assert Highlight.scope_at(highlight, 25, prefix <> "# comment") == :comment
      assert Highlight.scope_at(highlight, 25, prefix <> "// comment") == :comment
      assert Highlight.scope_at(highlight, 25, prefix <> "-- comment") == :comment
      assert Highlight.scope_at(highlight, 25, prefix <> "% comment") == :comment
      assert Highlight.scope_at(highlight, 25, prefix <> "\" comment") == :comment
      assert Highlight.scope_at(highlight, 25, prefix <> "<%!-- comment --%>") == :comment

      assert Highlight.scope_at(highlight, 25, "s = \"#\"; " <> prefix <> "_unused = value") ==
               :code

      assert Highlight.scope_at(highlight, 1) == :code
      assert Highlight.scope_at(highlight, 40) == :code
    end

    test "classifies block comments from source delimiters" do
      source = "let x = 1\n/* comment */"

      highlight =
        Highlight.new()
        |> Highlight.put_names(["comment"])
        |> Highlight.put_spans(1, [Span.new(10, byte_size(source), 0)])

      assert Highlight.scope_at(highlight, byte_size("let x = 1\n/* comm"), source) == :comment
    end

    test "does not treat string styling captures as string scope" do
      highlight =
        Highlight.new()
        |> Highlight.put_names(["string.special.symbol"])
        |> Highlight.put_spans(1, [Span.new(0, 5, 0)])

      assert Highlight.scope_at(highlight, 2, ":atom") == :code
    end

    test "uses innermost capture when spans overlap" do
      highlight =
        Highlight.new()
        |> Highlight.put_names(["string", "comment.documentation"])
        |> Highlight.put_spans(1, [
          Span.new(0, 20, 0),
          Span.new(5, 10, 1)
        ])

      assert Highlight.scope_at(highlight, 6) == :comment
      assert Highlight.scope_at(highlight, 12) == :string
    end

    test "ignores internal captures" do
      highlight =
        Highlight.new()
        |> Highlight.put_names(["string", "_delimiter"])
        |> Highlight.put_spans(1, [
          Span.new(0, 20, 0),
          Span.new(5, 10, 1)
        ])

      assert Highlight.scope_at(highlight, 6) == :string
    end
  end
end
