defmodule Minga.Editor.LspActionsTest do
  @moduledoc "Tests for LspActions: definition and hover response parsing and navigation."

  use ExUnit.Case, async: true

  alias Minga.Editor.LspActions

  # ── parse_location/1 ──────────────────────────────────────────────────────

  describe "parse_location/1" do
    test "parses a single Location" do
      location = %{
        "uri" => "file:///tmp/foo.ex",
        "range" => %{
          "start" => %{"line" => 10, "character" => 5},
          "end" => %{"line" => 10, "character" => 15}
        }
      }

      assert {"file:///tmp/foo.ex", 10, 5} = LspActions.parse_location(location)
    end

    test "parses an array of Locations (picks first)" do
      locations = [
        %{
          "uri" => "file:///tmp/first.ex",
          "range" => %{
            "start" => %{"line" => 1, "character" => 0},
            "end" => %{"line" => 1, "character" => 10}
          }
        },
        %{
          "uri" => "file:///tmp/second.ex",
          "range" => %{
            "start" => %{"line" => 20, "character" => 3},
            "end" => %{"line" => 20, "character" => 8}
          }
        }
      ]

      assert {"file:///tmp/first.ex", 1, 0} = LspActions.parse_location(locations)
    end

    test "parses a LocationLink" do
      link = %{
        "targetUri" => "file:///tmp/target.ex",
        "targetRange" => %{
          "start" => %{"line" => 42, "character" => 2},
          "end" => %{"line" => 42, "character" => 20}
        },
        "originSelectionRange" => %{
          "start" => %{"line" => 5, "character" => 0},
          "end" => %{"line" => 5, "character" => 10}
        }
      }

      assert {"file:///tmp/target.ex", 42, 2} = LspActions.parse_location(link)
    end

    test "returns nil for empty array" do
      assert LspActions.parse_location([]) == nil
    end

    test "returns nil for nil" do
      assert LspActions.parse_location(nil) == nil
    end

    test "returns nil for unrecognized format" do
      assert LspActions.parse_location("garbage") == nil
    end
  end

  # ── extract_hover_text/1 ──────────────────────────────────────────────────

  describe "extract_hover_text/1" do
    test "extracts plain text from MarkupContent" do
      content = %{"kind" => "plaintext", "value" => "some docs"}
      assert LspActions.extract_hover_text(content) == "some docs"
    end

    test "extracts and strips markdown from MarkupContent" do
      content = %{
        "kind" => "markdown",
        "value" => "```elixir\ndef hello, do: :world\n```\n\nSome description."
      }

      result = LspActions.extract_hover_text(content)
      assert result == "def hello, do: :world Some description."
    end

    test "handles plain string" do
      assert LspActions.extract_hover_text("just a string") == "just a string"
    end

    test "handles MarkedString array" do
      items = [
        %{"language" => "elixir", "value" => "def foo()"},
        "Some docs"
      ]

      result = LspActions.extract_hover_text(items)
      assert result == "def foo() | Some docs"
    end

    test "handles nil gracefully" do
      assert LspActions.extract_hover_text(nil) == ""
    end

    test "handles empty string" do
      assert LspActions.extract_hover_text("") == ""
    end

    test "strips code fences from markdown" do
      text = "```\ncode here\n```"
      result = LspActions.extract_hover_text(text)
      assert result == "code here"
    end
  end

  # ── handle_definition_response/2 ──────────────────────────────────────────

  describe "handle_definition_response/2" do
    test "sets status message on error" do
      state = fake_state()
      result = LspActions.handle_definition_response(state, {:error, %{"message" => "fail"}})
      assert result.status_msg == "Definition request failed"
    end

    test "sets status message when result is nil" do
      state = fake_state()
      result = LspActions.handle_definition_response(state, {:ok, nil})
      assert result.status_msg == "No definition found"
    end

    test "sets status message when result is empty list" do
      state = fake_state()
      result = LspActions.handle_definition_response(state, {:ok, []})
      assert result.status_msg == "No definition found"
    end
  end

  # ── handle_hover_response/2 ────────────────────────────────────────────────

  describe "handle_hover_response/2" do
    test "sets status message on error" do
      state = fake_state()
      result = LspActions.handle_hover_response(state, {:error, %{"message" => "fail"}})
      assert result.status_msg == "Hover request failed"
    end

    test "sets status message when result is nil" do
      state = fake_state()
      result = LspActions.handle_hover_response(state, {:ok, nil})
      assert result.status_msg == "No hover information"
    end

    test "creates hover popup for content" do
      state = fake_state()
      hover = %{"contents" => %{"kind" => "plaintext", "value" => "Returns :ok"}}
      result = LspActions.handle_hover_response(state, {:ok, hover})
      assert %Minga.Editor.HoverPopup{} = result.hover_popup
      assert result.hover_popup.focused == false
    end

    test "creates hover popup for markdown content" do
      state = fake_state()

      hover = %{
        "contents" => %{
          "kind" => "markdown",
          "value" => "```elixir\n@spec foo() :: :ok\n```"
        }
      }

      result = LspActions.handle_hover_response(state, {:ok, hover})
      assert %Minga.Editor.HoverPopup{} = result.hover_popup
      assert result.hover_popup.content_lines != []
    end

    test "handles hover with no contents key" do
      state = fake_state()
      result = LspActions.handle_hover_response(state, {:ok, %{"range" => %{}}})
      assert result.status_msg == "No hover information"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp fake_state do
    %{
      status_msg: nil,
      last_jump_pos: nil,
      hover_popup: nil,
      buffers: %{active: nil},
      viewport: %{rows: 24, cols: 80, top: 0}
    }
  end
end
