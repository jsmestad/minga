defmodule Minga.Editor.HighlightSyncTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.HighlightSync
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState

  # Minimal state for testing with a fake active buffer PID.
  defp base_state do
    pid = spawn(fn -> Process.sleep(:infinity) end)

    %EditorState{
      port_manager: nil,
      viewport: Viewport.new(24, 80),
      vim: VimState.new()
    }
    |> then(fn s -> %{s | buffers: %{s.buffers | active: pid}} end)
  end

  defp get_hl(state) do
    HighlightSync.get_active_highlight(state)
  end

  describe "handle_names/2" do
    test "stores capture names in highlight state" do
      state = base_state()
      names = ["keyword", "string", "comment"]
      new_state = HighlightSync.handle_names(state, names)

      assert get_hl(new_state).capture_names == names
    end

    test "replaces previous capture names" do
      state =
        base_state()
        |> HighlightSync.handle_names(["old"])
        |> HighlightSync.handle_names(["new1", "new2"])

      assert get_hl(state).capture_names == ["new1", "new2"]
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

      assert get_hl(state).version == 1
      assert get_hl(state).spans == List.to_tuple(spans)
    end

    test "rejects stale spans with older version" do
      spans1 = [%{start_byte: 0, end_byte: 5, capture_id: 0}]
      spans2 = [%{start_byte: 0, end_byte: 3, capture_id: 1}]

      state =
        base_state()
        |> HighlightSync.handle_spans(5, spans1)
        |> HighlightSync.handle_spans(3, spans2)

      assert get_hl(state).version == 5
      assert get_hl(state).spans == List.to_tuple(spans1)
    end

    test "accepts spans with equal version" do
      spans1 = [%{start_byte: 0, end_byte: 5, capture_id: 0}]
      spans2 = [%{start_byte: 0, end_byte: 3, capture_id: 1}]

      state =
        base_state()
        |> HighlightSync.handle_spans(5, spans1)
        |> HighlightSync.handle_spans(5, spans2)

      assert get_hl(state).spans == List.to_tuple(spans2)
    end
  end

  describe "setup_for_buffer/1" do
    test "returns state unchanged when no buffer" do
      state = %EditorState{
        port_manager: nil,
        viewport: Viewport.new(24, 80),
        vim: VimState.new()
      }

      assert HighlightSync.setup_for_buffer(state) == state
    end
  end

  describe "ensure_buffer_id_for/2" do
    test "assigns a new buffer_id for an unknown buffer pid" do
      state = base_state()
      other_pid = spawn(fn -> Process.sleep(:infinity) end)

      {id, new_state} = HighlightSync.ensure_buffer_id_for(state, other_pid)

      assert is_integer(id)
      assert id > 0
      assert Map.get(new_state.highlight.buffer_ids, other_pid) == id
      assert Map.get(new_state.highlight.reverse_buffer_ids, id) == other_pid
    end

    test "returns existing buffer_id for already-registered buffer" do
      state = base_state()
      other_pid = spawn(fn -> Process.sleep(:infinity) end)

      {id1, state2} = HighlightSync.ensure_buffer_id_for(state, other_pid)
      {id2, _state3} = HighlightSync.ensure_buffer_id_for(state2, other_pid)

      assert id1 == id2
    end

    test "assigns different ids for different buffers" do
      state = base_state()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      {id1, state2} = HighlightSync.ensure_buffer_id_for(state, pid1)
      {id2, _state3} = HighlightSync.ensure_buffer_id_for(state2, pid2)

      assert id1 != id2
    end
  end

  describe "touch_buffer/2" do
    test "updates last_active_at timestamp for given buffer pid" do
      state = base_state()
      other_pid = spawn(fn -> Process.sleep(:infinity) end)

      new_state = HighlightSync.touch_buffer(state, other_pid)

      assert Map.has_key?(new_state.highlight.last_active_at, other_pid)
    end
  end

  describe "request_reparse/1" do
    test "returns state unchanged when no buffer" do
      state = %EditorState{
        port_manager: nil,
        viewport: Viewport.new(24, 80),
        vim: VimState.new()
      }

      assert HighlightSync.request_reparse(state) == state
    end

    test "returns state unchanged when no highlighting active" do
      state = base_state()
      assert get_hl(state).capture_names == []
      assert HighlightSync.request_reparse(state) == state
    end
  end
end
