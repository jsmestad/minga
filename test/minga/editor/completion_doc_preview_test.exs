defmodule Minga.Editor.CompletionDocPreviewTest do
  @moduledoc """
  Tests for the completion documentation preview pane and
  completionItem/resolve flow.
  """

  use ExUnit.Case, async: true

  alias Minga.Editing.Completion
  alias Minga.Editor.CompletionHandling
  alias Minga.Editor.CompletionUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.UI.Theme
  alias Minga.Workspace.State, as: WorkspaceState

  @theme Theme.get!(:doom_one)

  defp make_state(completion) do
    ws = %WorkspaceState{
      viewport: %Viewport{top: 0, left: 0, rows: 24, cols: 80},
      completion: completion
    }

    %EditorState{
      port_manager: self(),
      workspace: ws
    }
  end

  # ── Completion item parsing ──────────────────────────────────────────────

  describe "parse_item/1 documentation extraction" do
    test "extracts plaintext documentation" do
      raw = %{"label" => "foo", "documentation" => "Some docs"}
      item = Completion.parse_item(raw)
      assert item.documentation == "Some docs"
    end

    test "extracts MarkupContent documentation" do
      raw = %{
        "label" => "foo",
        "documentation" => %{"kind" => "markdown", "value" => "**bold** docs"}
      }

      item = Completion.parse_item(raw)
      assert item.documentation == "**bold** docs"
    end

    test "handles missing documentation" do
      raw = %{"label" => "foo"}
      item = Completion.parse_item(raw)
      assert item.documentation == ""
    end

    test "preserves raw item for resolve" do
      raw = %{"label" => "foo", "kind" => 3, "detail" => "Function"}
      item = Completion.parse_item(raw)
      assert item.raw == raw
    end
  end

  # ── Documentation update ─────────────────────────────────────────────────

  describe "update_selected_documentation/2" do
    test "updates the selected item's documentation" do
      items = [
        Completion.parse_item(%{"label" => "a"}),
        Completion.parse_item(%{"label" => "b"}),
        Completion.parse_item(%{"label" => "c"})
      ]

      completion = Completion.new(items, {0, 0})
      updated = Completion.update_selected_documentation(completion, "New docs for a")
      selected = Completion.selected_item(updated)
      assert selected.documentation == "New docs for a"
    end

    test "returns unchanged when no selected item" do
      completion = Completion.new([], {0, 0})
      result = Completion.update_selected_documentation(completion, "docs")
      assert result == completion
    end
  end

  # ── Resolve debounce ─────────────────────────────────────────────────────

  describe "maybe_resolve_selected/1" do
    test "returns state unchanged when completion is nil" do
      state = make_state(nil)
      assert CompletionHandling.maybe_resolve_selected(state) == state
    end

    test "skips resolve when documentation already present" do
      items = [Completion.parse_item(%{"label" => "a", "documentation" => "Already here"})]
      completion = Completion.new(items, {0, 0})
      state = make_state(completion)
      result = CompletionHandling.maybe_resolve_selected(state)
      # No timer set because documentation is already present
      assert result.workspace.completion.resolve_timer == nil
    end

    test "sets a resolve timer when documentation is empty" do
      items = [Completion.parse_item(%{"label" => "a"})]
      completion = Completion.new(items, {0, 0})
      state = make_state(completion)
      result = CompletionHandling.maybe_resolve_selected(state)
      assert result.workspace.completion.resolve_timer != nil
    end

    test "skips when already resolved for this index" do
      items = [Completion.parse_item(%{"label" => "a"})]
      completion = %{Completion.new(items, {0, 0}) | last_resolved_index: 0}
      state = make_state(completion)
      result = CompletionHandling.maybe_resolve_selected(state)
      assert result.workspace.completion.resolve_timer == nil
    end
  end

  # ── Resolve response handling ───────────────────────────────────────────

  describe "handle_resolve_response/2" do
    test "updates selected item documentation on success" do
      items = [Completion.parse_item(%{"label" => "a"})]
      completion = Completion.new(items, {0, 0})
      state = make_state(completion)

      resolved = %{"documentation" => %{"kind" => "markdown", "value" => "Full docs"}}
      result = CompletionHandling.handle_resolve_response(state, {:ok, resolved})

      selected = Completion.selected_item(result.workspace.completion)
      assert selected.documentation == "Full docs"
      assert result.workspace.completion.last_resolved_index == 0
    end

    test "handles plain string documentation in resolve response" do
      items = [Completion.parse_item(%{"label" => "a"})]
      completion = Completion.new(items, {0, 0})
      state = make_state(completion)

      resolved = %{"documentation" => "Plain text docs"}
      result = CompletionHandling.handle_resolve_response(state, {:ok, resolved})

      selected = Completion.selected_item(result.workspace.completion)
      assert selected.documentation == "Plain text docs"
    end

    test "returns state unchanged on error" do
      items = [Completion.parse_item(%{"label" => "a"})]
      completion = Completion.new(items, {0, 0})
      state = make_state(completion)

      result = CompletionHandling.handle_resolve_response(state, {:error, "timeout"})
      assert result == state
    end

    test "returns state unchanged when completion is nil" do
      state = make_state(nil)
      result = CompletionHandling.handle_resolve_response(state, {:ok, %{}})
      assert result == state
    end
  end

  # ── Doc preview rendering ──────────────────────────────────────────────

  describe "CompletionUI doc preview rendering" do
    test "renders doc pane when selected item has documentation" do
      items = [
        Completion.parse_item(%{
          "label" => "my_function",
          "kind" => 3,
          "documentation" => "Returns the **result** of the computation."
        })
      ]

      completion = Completion.new(items, {0, 0})

      opts = %{
        cursor_row: 10,
        cursor_col: 5,
        viewport_rows: 24,
        viewport_cols: 120
      }

      draws = CompletionUI.render(completion, opts, @theme)
      # Should have draws for both the completion popup AND the doc pane
      assert draws != []
      # The doc pane draws should be at a different column than the popup
      cols = Enum.map(draws, fn {_r, c, _text, _s} -> c end) |> Enum.uniq()
      # Multiple column groups indicate popup + doc pane
      assert Enum.count(cols) > 2
    end

    test "does not render doc pane when documentation is empty" do
      items = [Completion.parse_item(%{"label" => "no_docs", "kind" => 3})]
      completion = Completion.new(items, {0, 0})

      opts = %{
        cursor_row: 10,
        cursor_col: 5,
        viewport_rows: 24,
        viewport_cols: 120
      }

      draws = CompletionUI.render(completion, opts, @theme)
      # Should only have popup draws, no doc pane
      assert draws != []
      # All draws should be near the cursor column (no side panel)
      cols = Enum.map(draws, fn {_r, c, _text, _s} -> c end)
      max_col = Enum.max(cols)
      # Without doc pane, nothing should extend far right
      assert max_col < 60
    end

    test "does not render doc pane when viewport too narrow" do
      items = [
        Completion.parse_item(%{
          "label" => "func",
          "kind" => 3,
          "documentation" => "Some docs"
        })
      ]

      completion = Completion.new(items, {0, 0})

      opts = %{
        cursor_row: 10,
        cursor_col: 30,
        viewport_rows: 24,
        viewport_cols: 60
      }

      draws = CompletionUI.render(completion, opts, @theme)
      assert draws != []
    end
  end
end
