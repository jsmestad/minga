defmodule MingaEditor.HighlightSyncTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Parser.Manager
  alias Minga.Language.Symbol
  alias MingaEditor.HighlightSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window

  setup do
    name = Module.concat(__MODULE__, "Parser#{System.unique_integer([:positive])}")
    manager = start_supervised!({Manager, name: name, parser_path: "/missing/minga-parser"})
    Process.put(:parser_manager, manager)
    :ok
  end

  # Minimal state for testing with a fake active buffer PID.
  defp base_state do
    pid = self()

    %EditorState{
      port_manager: nil,
      parser_manager: manager(),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new()
      }
    }
    |> then(fn s -> put_in(s.workspace.buffers.active, pid) end)
  end

  defp manager, do: Process.get(:parser_manager)

  defp get_hl(state) do
    HighlightSync.get_active_highlight(state)
  end

  describe "handle_names/2" do
    test "stores capture names in highlight state" do
      state = base_state()
      names = ["keyword", "string", "comment"]
      new_state = HighlightSync.handle_names(state, names)

      assert get_hl(new_state).capture_names == List.to_tuple(names)
    end

    test "replaces previous capture names" do
      state =
        base_state()
        |> HighlightSync.handle_names(["old"])
        |> HighlightSync.handle_names(["new1", "new2"])

      assert get_hl(state).capture_names == {"new1", "new2"}
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
        workspace: %MingaEditor.Session.State{
          viewport: Viewport.new(24, 80),
          editing: VimState.new()
        }
      }

      assert HighlightSync.setup_for_buffer(state) == state
    end
  end

  describe "setup_for_buffer_pid/2" do
    test "assigns a buffer_id for the given buffer" do
      state = base_state()
      {:ok, md_buf} = BufferProcess.start_link(content: "# Hello", filetype: :markdown)

      new_state = HighlightSync.setup_for_buffer_pid(state, md_buf)

      id = Manager.buffer_id(md_buf, manager())
      assert is_integer(id) and id > 0
      assert Manager.resolve_buffer(id, manager()) == md_buf
      assert Map.has_key?(new_state.highlighting.highlights, md_buf)
    end

    test "registers parser metadata in Parser.Manager" do
      state = base_state()
      {:ok, md_buf} = BufferProcess.start_link(content: "# Hello", filetype: :markdown)

      _new_state = HighlightSync.setup_for_buffer_pid(state, md_buf)

      assert is_integer(Manager.buffer_id(md_buf, manager()))
    end

    test "initializes highlight entry for the buffer" do
      state = base_state()
      {:ok, md_buf} = BufferProcess.start_link(content: "# Hello", filetype: :markdown)

      new_state = HighlightSync.setup_for_buffer_pid(state, md_buf)

      hl = HighlightSync.get_highlight(new_state, md_buf)
      assert hl != nil
    end

    test "is idempotent: second call reuses same buffer_id" do
      state = base_state()
      {:ok, md_buf} = BufferProcess.start_link(content: "# Hello", filetype: :markdown)

      state2 = HighlightSync.setup_for_buffer_pid(state, md_buf)
      id1 = Manager.buffer_id(md_buf, manager())

      _state3 = HighlightSync.setup_for_buffer_pid(state2, md_buf)
      id2 = Manager.buffer_id(md_buf, manager())

      assert id1 == id2
    end

    test "assigns different ids for different buffers" do
      state = base_state()
      {:ok, buf1} = BufferProcess.start_link(content: "# A", filetype: :markdown)
      {:ok, buf2} = BufferProcess.start_link(content: "# B", filetype: :markdown)

      state2 = HighlightSync.setup_for_buffer_pid(state, buf1)
      _state3 = HighlightSync.setup_for_buffer_pid(state2, buf2)

      id1 = Manager.buffer_id(buf1, manager())
      id2 = Manager.buffer_id(buf2, manager())
      assert id1 != id2
    end

    test "returns state unchanged for unsupported filetype" do
      state = base_state()
      {:ok, txt_buf} = BufferProcess.start_link(content: "hello", filetype: :text)

      _new_state = HighlightSync.setup_for_buffer_pid(state, txt_buf)

      assert Manager.buffer_id(txt_buf, manager()) == nil
    end

    test "clears seeded window document symbols for unsupported buffers" do
      {:ok, txt_buf} = BufferProcess.start_link(content: "hello", filetype: :text)
      stale_symbols = [%Symbol{kind: :function, name: "old", range: {0, 0, 0, 3}}]
      first_window = Window.set_document_symbols(Window.new(1, txt_buf, 24, 80), stale_symbols)
      second_window = Window.set_document_symbols(Window.new(2, txt_buf, 24, 80), stale_symbols)

      state =
        base_state()
        |> then(fn s ->
          %{s | workspace: %{s.workspace | buffers: %{s.workspace.buffers | active: txt_buf}}}
        end)
        |> then(fn s ->
          %{
            s
            | workspace: %{
                s.workspace
                | windows: %Windows{
                    map: %{1 => first_window, 2 => second_window},
                    active: 1,
                    next_id: 3
                  }
              }
          }
        end)

      new_state = HighlightSync.setup_for_buffer(state)

      assert Map.fetch!(new_state.workspace.windows.map, 1).document_symbols == []
      assert Map.fetch!(new_state.workspace.windows.map, 2).document_symbols == []
    end
  end

  describe "request_reparse/1" do
    test "returns state unchanged when no buffer" do
      state = %EditorState{
        port_manager: nil,
        workspace: %MingaEditor.Session.State{
          viewport: Viewport.new(24, 80),
          editing: VimState.new()
        }
      }

      assert HighlightSync.request_reparse(state) == state
    end

    test "does not register an unsupported buffer" do
      {:ok, buffer} = BufferProcess.start_link(content: "plain", filetype: :text)
      state = put_in(base_state().workspace.buffers.active, buffer)

      reparsed = HighlightSync.request_reparse(state)
      assert get_hl(reparsed).capture_names == {}
      assert Manager.buffer_id(buffer, manager()) == nil
    end

    test "explicit repair request preserves presentation while manager owns parsing" do
      {:ok, buffer} =
        BufferProcess.start_link(content: "defmodule Pending do\nend\n", filetype: :elixir)

      state = put_in(base_state().workspace.buffers.active, buffer)
      state = HighlightSync.setup_for_buffer(state)
      assert get_hl(state).capture_names == {}

      assert HighlightSync.request_reparse(state) == state
      assert is_integer(Manager.buffer_id(buffer, manager()))
    end
  end
end
