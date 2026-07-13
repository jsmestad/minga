defmodule MingaEditor.CompletionDocPreviewTest do
  @moduledoc """
  Tests for the completion documentation preview pane and
  completionItem/resolve flow.
  """

  use ExUnit.Case, async: true

  alias Minga.Editing.Completion
  alias MingaEditor.CompletionHandling
  alias MingaEditor.CompletionUI
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.Viewport
  alias MingaEditor.Session.State, as: SessionState

  defp make_state(completion) do
    ws = %SessionState{viewport: %Viewport{top: 0, left: 0, rows: 24, cols: 80}}

    modal =
      case completion do
        nil -> :none
        %Completion{} -> {:completion, CompletionPayload.new(:tab1, completion: completion)}
      end

    %EditorState{
      port_manager: self(),
      workspace: ws,
      shell_runtime:
        Runtime.new(Runtime.default_entry(), %MingaEditor.Shell.Traditional.State{modal: modal})
    }
  end

  defp completion_from(state), do: MingaEditor.Shell.Traditional.ModalWorkflow.completion(state)

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
      assert completion_from(result).resolve_timer == nil
    end

    test "sets a resolve timer when documentation is empty" do
      items = [Completion.parse_item(%{"label" => "a"})]
      completion = Completion.new(items, {0, 0})
      state = %{make_state(completion) | backend: :zig}
      result = CompletionHandling.maybe_resolve_selected(state)
      assert completion_from(result).resolve_timer != nil
    end

    test "skips resolve timer in headless mode" do
      items = [Completion.parse_item(%{"label" => "a"})]
      completion = Completion.new(items, {0, 0})
      state = make_state(completion)
      result = CompletionHandling.maybe_resolve_selected(state)
      assert completion_from(result).resolve_timer == nil
    end

    test "skips when already resolved for this index" do
      items = [Completion.parse_item(%{"label" => "a"})]
      completion = %{Completion.new(items, {0, 0}) | last_resolved_index: 0}
      state = make_state(completion)
      result = CompletionHandling.maybe_resolve_selected(state)
      assert completion_from(result).resolve_timer == nil
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

      selected = Completion.selected_item(completion_from(result))
      assert selected.documentation == "Full docs"
      assert completion_from(result).last_resolved_index == 0
    end

    test "handles plain string documentation in resolve response" do
      items = [Completion.parse_item(%{"label" => "a"})]
      completion = Completion.new(items, {0, 0})
      state = make_state(completion)

      resolved = %{"documentation" => "Plain text docs"}
      result = CompletionHandling.handle_resolve_response(state, {:ok, resolved})

      selected = Completion.selected_item(completion_from(result))
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

  describe "CompletionUI.menu_rect/2" do
    # The cell-grid `render/3` painter (menu border, selection rail, and the
    # markdown doc-preview pane) was removed in #2311. The completion menu now
    # renders natively from `Minga.RenderModel.UI.Completion` via the 0x78 GUI
    # opcode. `menu_rect/2` is the live surface that resolves the menu's screen
    # rect for the FocusTree's hit region.
    #
    # The doc-preview capability the cell painter drew is restored in #2322: the
    # semantic Completion model now carries the selected item's `documentation`
    # (truncated to a 4 KiB cap in CompletionBuilder), the 0x78 payload ships it
    # via the schema (gui_completion conditional_tail), and both frontends render
    # a preview pane. See completion_builder_test.exs for the model-level coverage
    # and the schema golden manifest for the wire round-trip.
    test "returns the bordered menu rect anchored below the cursor" do
      items = [Completion.parse_item(%{"label" => "alpha", "kind" => 3, "detail" => "Function"})]
      completion = Completion.new(items, {0, 0})

      opts = %{
        cursor_row: 10,
        cursor_col: 5,
        viewport_rows: 24,
        viewport_cols: 80
      }

      assert {12, 6, _width, 1} = CompletionUI.menu_rect(completion, opts)
    end

    test "returns nil when there are no visible items" do
      completion = Completion.new([], {0, 0})

      opts = %{
        cursor_row: 10,
        cursor_col: 5,
        viewport_rows: 24,
        viewport_cols: 80
      }

      assert CompletionUI.menu_rect(completion, opts) == nil
      assert CompletionUI.menu_rect(nil, opts) == nil
    end
  end
end
