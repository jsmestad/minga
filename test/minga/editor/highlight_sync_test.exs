defmodule Minga.Editor.HighlightSyncTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.HighlightSync
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState

  # Minimal state for testing — no real port or buffer needed for
  # handle_names and handle_spans.
  defp base_state do
    %EditorState{
      port_manager: nil,
      viewport: Viewport.new(24, 80),
      vim: VimState.new()
    }
  end

  describe "handle_names/2" do
    test "stores capture names in highlight state" do
      state = base_state()
      names = ["keyword", "string", "comment"]
      new_state = HighlightSync.handle_names(state, names)

      assert new_state.highlight.current.capture_names == names
    end

    test "replaces previous capture names" do
      state =
        base_state()
        |> HighlightSync.handle_names(["old"])
        |> HighlightSync.handle_names(["new1", "new2"])

      assert state.highlight.current.capture_names == ["new1", "new2"]
    end
  end

  describe "handle_spans/3" do
    test "stores spans with version" do
      spans = [
        %{start_byte: 0, end_byte: 9, capture_id: 0},
        %{start_byte: 10, end_byte: 15, capture_id: 1}
      ]

      state =
        base_state()
        |> HighlightSync.handle_spans(1, spans)

      assert state.highlight.current.version == 1
      assert state.highlight.current.spans == List.to_tuple(spans)
    end

    test "rejects stale spans with older version" do
      spans1 = [%{start_byte: 0, end_byte: 5, capture_id: 0}]
      spans2 = [%{start_byte: 0, end_byte: 3, capture_id: 1}]

      state =
        base_state()
        |> HighlightSync.handle_spans(5, spans1)
        |> HighlightSync.handle_spans(3, spans2)

      assert state.highlight.current.version == 5
      assert state.highlight.current.spans == List.to_tuple(spans1)
    end

    test "accepts spans with equal version" do
      spans1 = [%{start_byte: 0, end_byte: 5, capture_id: 0}]
      spans2 = [%{start_byte: 0, end_byte: 3, capture_id: 1}]

      state =
        base_state()
        |> HighlightSync.handle_spans(5, spans1)
        |> HighlightSync.handle_spans(5, spans2)

      assert state.highlight.current.spans == List.to_tuple(spans2)
    end
  end

  describe "setup_for_buffer/1" do
    test "returns state unchanged when no buffer" do
      state = base_state()
      assert HighlightSync.setup_for_buffer(state) == state
    end
  end

  describe "request_reparse/1" do
    test "returns state unchanged when no buffer" do
      state = base_state()
      assert HighlightSync.request_reparse(state) == state
    end

    test "returns state unchanged when no highlighting active" do
      state = base_state()
      assert state.highlight.current.capture_names == []
      assert HighlightSync.request_reparse(state) == state
    end
  end
end
