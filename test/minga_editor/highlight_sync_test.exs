defmodule MingaEditor.HighlightSyncTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Buffers
  alias MingaEditor.Session.State, as: SessionState
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Parser.Manager
  alias Minga.Language.Symbol
  alias MingaEditor.HighlightSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
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
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      parser: %MingaEditor.State.Parser{parser_manager: manager()},
      workspace: %MingaEditor.Session.State{editing: VimState.new()}
    }
    |> then(fn s ->
      %{
        s
        | workspace:
            SessionState.set_buffers(
              s.workspace,
              Buffers.set_active_override(s.workspace.buffers, pid)
            )
      }
    end)
  end

  defp manager, do: Process.get(:parser_manager)

  defp get_hl(state) do
    HighlightSync.get_active_highlight(state)
  end

  describe "setup_for_buffer/1" do
    test "returns state unchanged when no buffer" do
      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{port_manager: nil},
        workspace: %MingaEditor.Session.State{editing: VimState.new()}
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
      assert Map.has_key?(new_state.parser.highlighting.highlights, md_buf)
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

  describe "ensure_active_buffer_presentation/2" do
    test "sets up real unlisted active buffers and excludes fake or nil active values" do
      {:ok, real_buffer} =
        BufferProcess.start_link(content: "defmodule Real do\nend\n", filetype: :elixir)

      state = base_state() |> put_active_buffer(real_buffer, [])

      ensured = HighlightSync.ensure_active_buffer_presentation(state, nil)

      assert ensured.workspace.buffers.active == real_buffer
      assert ensured.workspace.buffers.list == []
      assert is_integer(Manager.buffer_id(real_buffer, manager()))
      assert Map.has_key?(ensured.parser.highlighting.highlights, real_buffer)

      fake_buffer = start_fake_buffer()
      fake_state = base_state() |> put_active_buffer(fake_buffer, [])

      assert HighlightSync.ensure_active_buffer_presentation(fake_state, nil) == fake_state
      assert Manager.buffer_id(fake_buffer, manager()) == nil
      refute_received {:fake_buffer_call, :filetype}

      nil_state = base_state() |> put_active_buffer(nil, [])
      assert HighlightSync.ensure_active_buffer_presentation(nil_state, nil) == nil_state
    end

    test "preserves deferred frontend setup and synchronous headless setup" do
      {:ok, headless_buffer} =
        BufferProcess.start_link(content: "defmodule Headless do\nend\n", filetype: :elixir)

      headless_state = base_state() |> put_active_buffer(headless_buffer, [])

      headless = HighlightSync.ensure_active_buffer_presentation(headless_state, nil)

      assert is_integer(Manager.buffer_id(headless_buffer, manager()))
      assert Map.has_key?(headless.parser.highlighting.highlights, headless_buffer)
      refute_received :setup_highlight

      {:ok, frontend_buffer} =
        BufferProcess.start_link(content: "defmodule Frontend do\nend\n", filetype: :elixir)

      frontend_state =
        base_state()
        |> put_active_buffer(frontend_buffer, [])
        |> then(fn state -> %{state | frontend: %{state.frontend | backend: :gui}} end)

      frontend = HighlightSync.ensure_active_buffer_presentation(frontend_state, nil)

      assert frontend == frontend_state
      assert Manager.buffer_id(frontend_buffer, manager()) == nil
      refute Map.has_key?(frontend.parser.highlighting.highlights, frontend_buffer)
      assert_received :setup_highlight
      refute_received :setup_highlight
    end
  end

  describe "request_reparse/1" do
    test "returns state unchanged when no buffer" do
      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{port_manager: nil},
        workspace: %MingaEditor.Session.State{editing: VimState.new()}
      }

      assert HighlightSync.request_reparse(state) == state
    end

    test "does not register an unsupported buffer" do
      {:ok, buffer} = BufferProcess.start_link(content: "plain", filetype: :text)

      state = %{
        base_state()
        | workspace:
            SessionState.set_buffers(
              base_state().workspace,
              Buffers.set_active_override(base_state().workspace.buffers, buffer)
            )
      }

      reparsed = HighlightSync.request_reparse(state)
      assert get_hl(reparsed).capture_names == {}
      assert Manager.buffer_id(buffer, manager()) == nil
    end

    test "explicit repair request preserves presentation while manager owns parsing" do
      {:ok, buffer} =
        BufferProcess.start_link(content: "defmodule Pending do\nend\n", filetype: :elixir)

      state = %{
        base_state()
        | workspace:
            SessionState.set_buffers(
              base_state().workspace,
              Buffers.set_active_override(base_state().workspace.buffers, buffer)
            )
      }

      state = HighlightSync.setup_for_buffer(state)
      assert get_hl(state).capture_names == {}

      assert HighlightSync.request_reparse(state) == state
      assert is_integer(Manager.buffer_id(buffer, manager()))
    end
  end

  defp put_active_buffer(state, buffer, list) do
    buffers = %{state.workspace.buffers | active: buffer, list: list, active_index: 0}
    %{state | workspace: SessionState.set_buffers(state.workspace, buffers)}
  end

  defp start_fake_buffer do
    parent = self()

    pid =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, :filetype} ->
            send(parent, {:fake_buffer_call, :filetype})
            GenServer.reply(from, :elixir)
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end
end
