defmodule MingaEditor.Handlers.LspEventHandlerTest do
  @moduledoc """
  Handler tests for `MingaEditor.Handlers.LspEventHandler`.
  """

  # async: false because these tests register clients in the singleton LSP SyncServer ETS table.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Completion
  alias MingaEditor.CompletionHandling
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.Handlers.LspEventHandler
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.LSP.FormatOperation
  alias MingaEditor.State.Buffers
  alias MingaEditor.SignatureHelp
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.UI.Highlight
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  describe "handle/2" do
    test "tracked atom response deletes pending ref and returns render_now" do
      state = base_state()
      ref = make_ref()
      state = put_lsp_pending(state, ref, :definition)

      {new_state, effects} = LspEventHandler.handle(state, {:lsp_response, ref, {:ok, nil}})

      assert new_state.workspace.lsp_pending == %{}
      assert effects == [:render_now]
    end

    test "tuple-keyed hover_mouse response returns render_now without crashing" do
      state = base_state()
      ref = make_ref()
      state = put_lsp_pending(state, ref, {:hover_mouse, 12, 34})

      {new_state, effects} = LspEventHandler.handle(state, {:lsp_response, ref, {:ok, nil}})

      assert new_state.workspace.lsp_pending == %{}
      assert effects == [:render_now]
    end

    test "inlay debounce clears the timer ref" do
      state = base_state()
      timer = make_ref()
      state = EditorState.update_lsp(state, &LSPState.set_inlay_hint_timer(&1, timer, 9))

      {new_state, effects} = LspEventHandler.handle(state, :inlay_hint_scroll_debounce)

      assert new_state.lsp.inlay_hint_debounce_timer == nil
      assert effects == []
    end

    test "document highlight debounce clears the timer ref" do
      state = base_state()
      timer = make_ref()
      state = EditorState.update_lsp(state, &LSPState.set_highlight_timer(&1, timer))

      {new_state, effects} = LspEventHandler.handle(state, :document_highlight_debounce)

      assert new_state.lsp.highlight_debounce_timer == nil
      assert effects == []
    end

    test "completion debounce writes the flushed completion trigger back and sends a request" do
      state = file_buffer_state("foo_bar\n")
      client = start_fake_lsp_client()
      timer = make_ref()
      trigger = %{CompletionTrigger.new() | debounce_timer: timer}
      payload = CompletionPayload.new(:tab1, trigger: trigger)
      state = EditorState.set_modal(state, {:completion, payload})
      buffer = state.workspace.buffers.active

      {new_state, effects} =
        LspEventHandler.handle(state, {:completion_debounce, [client], buffer})

      assert effects == []
      assert_receive {:lsp_request, "textDocument/completion", _params, caller, ref}
      assert caller == self()

      new_trigger = ModalOverlay.completion_trigger(new_state)
      assert new_trigger.pending_ref == ref
      assert MapSet.member?(new_trigger.pending_refs, ref)
      assert new_trigger.debounce_timer == timer
    end

    test "completion resolve routes the request and records the pending ref" do
      state = buffer_state("hello\n")
      client = start_fake_lsp_client()
      buffer = state.workspace.buffers.active
      register_lsp_client(buffer, client)

      item = %{
        "label" => "resolve-me",
        "kind" => 3,
        "documentation" => "",
        "sortText" => "resolve-me"
      }

      completion = Completion.new(Completion.parse_response(%{"items" => [item]}), {0, 0})
      trigger = %{CompletionTrigger.new() | pending_ref: make_ref(), pending_refs: MapSet.new()}
      payload = CompletionPayload.new(:tab1, completion: completion, trigger: trigger)
      state = EditorState.set_modal(state, {:completion, payload})

      {new_state, effects} = LspEventHandler.handle(state, {:completion_resolve, 0})

      assert effects == []

      assert_receive {:lsp_request, "completionItem/resolve", %{"label" => "resolve-me"}, caller,
                      ref}

      assert caller == self()

      assert new_state.workspace.lsp_pending == %{ref => :completion_resolve}
    end

    test "tracked signature help response updates state and returns render_now" do
      state = base_state()
      ref = make_ref()
      state = put_lsp_pending(state, ref, :signature_help)

      response = %{
        "signatures" => [
          %{"label" => "foo(arg)", "parameters" => [%{"label" => "arg"}]}
        ],
        "activeSignature" => 0,
        "activeParameter" => 0
      }

      {new_state, effects} = LspEventHandler.handle(state, {:lsp_response, ref, {:ok, response}})

      assert new_state.workspace.lsp_pending == %{}
      assert effects == [:render_now]

      assert %SignatureHelp{signatures: [%{label: "foo(arg)"}]} =
               Runtime.state(new_state.shell_runtime).signature_help
    end

    test "tracked semantic token response updates highlights and returns render_now" do
      state = file_buffer_state("hello\n")
      buffer = state.workspace.buffers.active
      client = start_fake_lsp_client()

      register_lsp_client(buffer, client)

      state =
        EditorState.update_highlight(state, fn highlighting ->
          Highlighting.put_highlight(highlighting, buffer, Highlight.new())
        end)

      ref = make_ref()
      state = put_lsp_pending(state, ref, {:semantic_tokens, buffer})

      {new_state, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref, {:ok, %{"data" => [0, 0, 5, 0, 0]}}})

      assert new_state.workspace.lsp_pending == %{}
      assert effects == [:render_now]

      highlight = Map.fetch!(new_state.highlighting.highlights, buffer)
      assert Tuple.to_list(highlight.capture_names) == ["@lsp.type.variable"]
      assert [%{layer: 2}] = Tuple.to_list(highlight.spans)
    end

    test "untracked completion response is processed off-thread, then becomes visible" do
      state = buffer_state("hello\n")
      ref = make_ref()
      trigger = %{CompletionTrigger.new() | pending_ref: ref, pending_refs: MapSet.new([ref])}
      payload = CompletionPayload.new(:tab1, trigger: trigger)
      state = EditorState.set_modal(state, {:completion, payload})

      completion_result = %{
        "items" => [
          %{
            "label" => "hello_world",
            "kind" => 3,
            "documentation" => "docs",
            "sortText" => "hello_world"
          }
        ]
      }

      {new_state, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref, {:ok, completion_result}})

      assert effects == [:render_now]

      # The handler only does cheap ref bookkeeping: pending refs are cleared
      # synchronously, but the parse/sort/filter is deferred to a Task (#2633),
      # so the menu is not yet visible right after handle/2 returns.
      assert ModalOverlay.completion(new_state) == nil

      new_trigger = ModalOverlay.completion_trigger(new_state)
      assert new_trigger.pending_ref == nil
      assert MapSet.new() == new_trigger.pending_refs

      # Drive the async result the Task sends back, exactly as the Editor's
      # {:completion_processed, ...} handle_info clause does, and confirm the
      # completion ultimately becomes visible.
      assert_receive {:completion_processed, gen, mode, processed, trigger_pos}, 5_000
      applied = CompletionHandling.apply_processed(new_state, gen, mode, processed, trigger_pos)

      completion = ModalOverlay.completion(applied)
      assert %Completion{} = completion
      assert [%{label: "hello_world"}] = completion.filtered
      assert completion.selected == 0
    end
  end

  describe "formatting response" do
    test "applies edits when buffer version matches" do
      state = base_state()
      buf = state.workspace.buffers.active
      version = Minga.Buffer.version(buf)
      ref = make_ref()
      state = track_format(state, ref, buf, version)

      edits = [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 8}
          },
          "newText" => "LINE ONE"
        }
      ]

      {new_state, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref, {:ok, edits}})

      assert effects == [:render_now]
      refute LSPState.format_active?(new_state.lsp, ref)
      assert Minga.Buffer.content(buf) =~ "LINE ONE"
    end

    test "skips edits when buffer version changed (staleness guard)" do
      state = base_state()
      buf = state.workspace.buffers.active
      old_version = Minga.Buffer.version(buf)
      ref = make_ref()
      state = track_format(state, ref, buf, old_version)

      Minga.Buffer.replace_content(buf, "modified content\n")

      edits = [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 8}
          },
          "newText" => "STALE"
        }
      ]

      {new_state, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref, {:ok, edits}})

      assert effects == [:render_now]
      assert Minga.Buffer.content(buf) == "modified content\n"
      assert EditorState.status_msg(new_state) =~ "Buffer changed"
    end

    test "a mutation queued after the LSP content read makes the commit stale" do
      state = base_state()
      buf = state.workspace.buffers.active
      version = Minga.Buffer.version(buf)
      ref = make_ref()
      state = track_format(state, ref, buf, version)

      edits = [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 8}
          },
          "newText" => "STALE"
        }
      ]

      :ok = :sys.suspend(buf)

      task =
        Task.async(fn ->
          receive do
            :apply_result ->
              LspEventHandler.handle(state, {:lsp_response, ref, {:ok, edits}})
          end
        end)

      task_pid = task.pid
      1 = :erlang.trace(task_pid, true, [:send])
      send(task_pid, :apply_result)

      assert_receive {:trace, ^task_pid, :send, {:"$gen_call", {_from, _tag}, :content}, ^buf}

      insert_tag = make_ref()

      send(
        buf,
        {:"$gen_call", {self(), insert_tag}, {:insert_text, "!", Minga.Buffer.EditSource.user()}}
      )

      :ok = :sys.resume(buf)
      assert_receive {^insert_tag, :ok}
      {new_state, effects} = Task.await(task)

      assert effects == [:render_now]
      assert Minga.Buffer.content(buf) =~ "!line one"
      assert EditorState.status_msg(new_state) =~ "Buffer changed"
    end

    test "does not apply edits to a read-only buffer" do
      state = base_state()
      buf = state.workspace.buffers.active
      version = Minga.Buffer.version(buf)
      :ok = Minga.Buffer.set_read_only(buf, true)
      ref = make_ref()
      state = track_format(state, ref, buf, version)

      edits = [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 8}
          },
          "newText" => "READ ONLY"
        }
      ]

      {new_state, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref, {:ok, edits}})

      assert effects == [:render_now]
      assert Minga.Buffer.content(buf) =~ "line one"
      assert EditorState.status_msg(new_state) =~ "read-only"
    end

    test "drops edits when the target buffer exited" do
      state = base_state()
      buf = state.workspace.buffers.active
      version = Minga.Buffer.version(buf)
      ref = make_ref()
      state = track_format(state, ref, buf, version)
      monitor = Process.monitor(buf)
      Process.exit(buf, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^buf, :killed}

      edits = [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 8}
          },
          "newText" => "CLOSED"
        }
      ]

      {new_state, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref, {:ok, edits}})

      assert effects == [:render_now]
      assert EditorState.status_msg(new_state) =~ "closed"
    end

    test "handles nil response (no formatting changes)" do
      state = base_state()
      buf = state.workspace.buffers.active
      ref = make_ref()
      state = track_format(state, ref, buf, Minga.Buffer.version(buf))

      {new_state, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref, {:ok, nil}})

      assert effects == [:render_now]
      assert EditorState.status_msg(new_state) =~ "No formatting changes"
    end

    test "handles error response" do
      state = base_state()
      buf = state.workspace.buffers.active
      ref = make_ref()
      state = track_format(state, ref, buf, Minga.Buffer.version(buf))

      {new_state, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref, {:error, :timeout}})

      assert effects == [:render_now]
      assert EditorState.status_msg(new_state) =~ "Format error"
    end

    test "rejects invalid or overlapping server edits without changing content" do
      state = base_state()
      buf = state.workspace.buffers.active
      ref = make_ref()
      state = track_format(state, ref, buf, Minga.Buffer.version(buf))

      edits = [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 8}
          },
          "newText" => "first"
        },
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 4},
            "end" => %{"line" => 0, "character" => 9}
          },
          "newText" => "second"
        }
      ]

      {new_state, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref, {:ok, edits}})

      assert effects == [:render_now]
      assert Minga.Buffer.content(buf) == "line one\nline two\nline three"
      assert new_state.shell_state.status_msg =~ "Invalid LSP"
    end
  end

  describe "format timer events" do
    test "spinner shows status when format is still pending" do
      state = base_state()
      ref = make_ref()
      buf = state.workspace.buffers.active
      state = track_format(state, ref, buf, 0)

      {new_state, effects} = LspEventHandler.handle(state, {:lsp_format_spinner, ref})

      assert effects == [:render_now]
      assert EditorState.status_msg(new_state) =~ "Formatting"
    end

    test "spinner is no-op when format already completed" do
      state = base_state()
      ref = make_ref()

      {new_state, effects} = LspEventHandler.handle(state, {:lsp_format_spinner, ref})

      assert effects == []
      assert new_state == state
    end

    test "cancellable shows Esc hint when format is still pending" do
      state = base_state()
      ref = make_ref()
      buf = state.workspace.buffers.active
      state = track_format(state, ref, buf, 0)

      {new_state, effects} = LspEventHandler.handle(state, {:lsp_format_cancellable, ref})

      assert effects == [:render_now]
      assert EditorState.status_msg(new_state) =~ "Esc to cancel"
    end

    test "timeout drops pending and sets timeout status" do
      state = base_state()
      ref = make_ref()
      buf = state.workspace.buffers.active
      state = track_format(state, ref, buf, 0)

      {new_state, effects} = LspEventHandler.handle(state, {:lsp_format_timeout, ref})

      assert effects == [:render_now]
      refute LSPState.format_active?(new_state.lsp, ref)
      assert EditorState.status_msg(new_state) =~ "timed out"
      assert_receive {:lsp_cancel, ^ref}
    end

    test "late response after timeout is ignored" do
      state = base_state()
      ref = make_ref()
      buf = state.workspace.buffers.active
      state = track_format(state, ref, buf, Minga.Buffer.version(buf))

      {timed_out, [:render_now]} =
        LspEventHandler.handle(state, {:lsp_format_timeout, ref})

      assert_receive {:lsp_cancel, ^ref}

      edits = [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 8}
          },
          "newText" => "LATE"
        }
      ]

      {after_late, effects} =
        LspEventHandler.handle(timed_out, {:lsp_response, ref, {:ok, edits}})

      assert effects == [:render_now]
      assert Minga.Buffer.content(buf) == "line one\nline two\nline three"
      assert EditorState.status_msg(after_late) =~ "timed out"
    end

    test "timeout is no-op when format already completed" do
      state = base_state()
      ref = make_ref()

      {new_state, effects} = LspEventHandler.handle(state, {:lsp_format_timeout, ref})

      assert effects == []
      assert new_state == state
    end
  end

  defp put_lsp_pending(state, ref, kind) do
    EditorState.put_lsp_pending(state, ref, kind)
  end

  defp track_format(state, ref, buffer, version, opts \\ []) do
    operation =
      FormatOperation.new(
        client: Keyword.get(opts, :client, start_fake_lsp_client()),
        ref: ref,
        buffer: buffer,
        version: version,
        encoding: Keyword.get(opts, :encoding, :utf8),
        spinner_timer: make_ref(),
        cancellable_timer: make_ref(),
        timeout_timer: make_ref()
      )

    EditorState.update_lsp(state, &LSPState.track_format(&1, operation))
  end

  defp base_state do
    buffer_state("line one\nline two\nline three")
  end

  defp buffer_state(content) do
    buffer = start_supervised!({BufferProcess, content: content}, id: {:buffer, make_ref()})
    workspace = workspace_for(buffer)

    %EditorState{port_manager: self(), workspace: workspace}
  end

  defp register_lsp_client(buffer, client) do
    Minga.LSP.SyncServer.put_clients(buffer, [client])

    on_exit(fn ->
      try do
        Minga.LSP.SyncServer.remove_buffer(buffer)
      rescue
        ArgumentError -> :ok
      end
    end)
  end

  defp file_buffer_state(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "lsp-event-handler-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)

    buffer =
      start_supervised!(
        {BufferProcess, file_path: path, content: content},
        id: {:buffer, make_ref()}
      )

    workspace = workspace_for(buffer)
    %EditorState{port_manager: self(), workspace: workspace}
  end

  defp workspace_for(buffer) do
    %MingaEditor.Session.State{
      viewport: Viewport.new(24, 80),
      editing: VimState.new(),
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buffer, 24, 80)},
        active: 1,
        next_id: 2
      }
    }
  end

  defp start_fake_lsp_client do
    parent = self()

    start_supervised!(
      {Task, fn -> fake_lsp_client_loop(parent) end},
      id: {:fake_lsp_client, make_ref()}
    )
  end

  defp fake_lsp_client_loop(parent) do
    receive do
      {:"$gen_call", from, :semantic_token_legend} ->
        GenServer.reply(from, {["variable"], []})
        fake_lsp_client_loop(parent)

      {:"$gen_call", from, :encoding} ->
        GenServer.reply(from, :utf16)
        fake_lsp_client_loop(parent)

      {:"$gen_call", from, {:cancel_request, ref}} ->
        send(parent, {:lsp_cancel, ref})
        GenServer.reply(from, :ok)
        fake_lsp_client_loop(parent)

      {:"$gen_cast", {:async_request, method, params, caller, ref}} ->
        send(parent, {:lsp_request, method, params, caller, ref})
        fake_lsp_client_loop(parent)

      _other ->
        fake_lsp_client_loop(parent)
    end
  end
end
