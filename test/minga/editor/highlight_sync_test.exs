defmodule Minga.Editor.HighlightSyncTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
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

  describe "setup_for_buffer_pid/2" do
    test "assigns a buffer_id for the given buffer" do
      state = base_state()
      {:ok, md_buf} = BufferServer.start_link(content: "# Hello", filetype: :markdown)

      new_state = HighlightSync.setup_for_buffer_pid(state, md_buf)

      # Should have a buffer_id mapping
      assert Map.has_key?(new_state.highlight.buffer_ids, md_buf)
      id = Map.get(new_state.highlight.buffer_ids, md_buf)
      assert is_integer(id)
      assert id > 0
      # Reverse mapping should exist
      assert Map.get(new_state.highlight.reverse_buffer_ids, id) == md_buf
    end

    test "sets last_active_at timestamp" do
      state = base_state()
      {:ok, md_buf} = BufferServer.start_link(content: "# Hello", filetype: :markdown)

      new_state = HighlightSync.setup_for_buffer_pid(state, md_buf)

      assert Map.has_key?(new_state.highlight.last_active_at, md_buf)
    end

    test "initializes highlight entry for the buffer" do
      state = base_state()
      {:ok, md_buf} = BufferServer.start_link(content: "# Hello", filetype: :markdown)

      new_state = HighlightSync.setup_for_buffer_pid(state, md_buf)

      hl = HighlightSync.get_highlight(new_state, md_buf)
      assert hl != nil
    end

    test "is idempotent: second call reuses same buffer_id" do
      state = base_state()
      {:ok, md_buf} = BufferServer.start_link(content: "# Hello", filetype: :markdown)

      state2 = HighlightSync.setup_for_buffer_pid(state, md_buf)
      id1 = Map.get(state2.highlight.buffer_ids, md_buf)

      state3 = HighlightSync.setup_for_buffer_pid(state2, md_buf)
      id2 = Map.get(state3.highlight.buffer_ids, md_buf)

      assert id1 == id2
    end

    test "assigns different ids for different buffers" do
      state = base_state()
      {:ok, buf1} = BufferServer.start_link(content: "# A", filetype: :markdown)
      {:ok, buf2} = BufferServer.start_link(content: "# B", filetype: :markdown)

      state2 = HighlightSync.setup_for_buffer_pid(state, buf1)
      state3 = HighlightSync.setup_for_buffer_pid(state2, buf2)

      id1 = Map.get(state3.highlight.buffer_ids, buf1)
      id2 = Map.get(state3.highlight.buffer_ids, buf2)
      assert id1 != id2
    end

    test "returns state unchanged for unsupported filetype" do
      state = base_state()
      {:ok, txt_buf} = BufferServer.start_link(content: "hello", filetype: :text)

      new_state = HighlightSync.setup_for_buffer_pid(state, txt_buf)

      refute Map.has_key?(new_state.highlight.buffer_ids, txt_buf)
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
