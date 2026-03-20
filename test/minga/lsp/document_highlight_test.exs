defmodule Minga.LSP.DocumentHighlightTest do
  use ExUnit.Case, async: true

  alias Minga.LSP.DocumentHighlight

  describe "from_lsp/1" do
    test "parses a text highlight (kind 1)" do
      lsp = %{
        "range" => %{
          "start" => %{"line" => 5, "character" => 10},
          "end" => %{"line" => 5, "character" => 15}
        },
        "kind" => 1
      }

      result = DocumentHighlight.from_lsp(lsp)
      assert %DocumentHighlight{} = result
      assert result.start_line == 5
      assert result.start_col == 10
      assert result.end_line == 5
      assert result.end_col == 15
      assert result.kind == :text
    end

    test "parses a read highlight (kind 2)" do
      lsp = %{
        "range" => %{
          "start" => %{"line" => 10, "character" => 0},
          "end" => %{"line" => 10, "character" => 8}
        },
        "kind" => 2
      }

      assert %DocumentHighlight{kind: :read} = DocumentHighlight.from_lsp(lsp)
    end

    test "parses a write highlight (kind 3)" do
      lsp = %{
        "range" => %{
          "start" => %{"line" => 3, "character" => 4},
          "end" => %{"line" => 3, "character" => 12}
        },
        "kind" => 3
      }

      assert %DocumentHighlight{kind: :write} = DocumentHighlight.from_lsp(lsp)
    end

    test "defaults to :text when kind is nil" do
      lsp = %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 0},
          "end" => %{"line" => 0, "character" => 5}
        }
      }

      assert %DocumentHighlight{kind: :text} = DocumentHighlight.from_lsp(lsp)
    end

    test "defaults to :text for unknown kind values" do
      lsp = %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 0},
          "end" => %{"line" => 0, "character" => 5}
        },
        "kind" => 99
      }

      assert %DocumentHighlight{kind: :text} = DocumentHighlight.from_lsp(lsp)
    end
  end
end
