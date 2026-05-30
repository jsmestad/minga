defmodule MingaEditor.Handlers.LspEventHandlerTest do
  @moduledoc """
  Handler tests for `MingaEditor.Handlers.LspEventHandler`.
  """

  # async: false because these tests register clients in the singleton LSP SyncServer ETS table.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Completion
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.Handlers.LspEventHandler
  alias MingaEditor.State, as: EditorState
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
               new_state.shell_state.signature_help
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

      highlight = Map.fetch!(new_state.workspace.highlight.highlights, buffer)
      assert Tuple.to_list(highlight.capture_names) == ["@lsp.type.variable"]
      assert [%{layer: 2}] = Tuple.to_list(highlight.spans)
    end

    test "untracked completion response updates the visible completion and returns render_now" do
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

      completion = ModalOverlay.completion(new_state)
      assert %Completion{} = completion
      assert [%{label: "hello_world"}] = completion.filtered
      assert completion.selected == 0

      new_trigger = ModalOverlay.completion_trigger(new_state)
      assert new_trigger.pending_ref == nil
      assert MapSet.new() == new_trigger.pending_refs
    end
  end

  defp put_lsp_pending(state, ref, kind) do
    EditorState.put_lsp_pending(state, ref, kind)
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
    :ets.insert(Minga.LSP.SyncServer.Registry, {buffer, [client]})

    on_exit(fn ->
      if :ets.whereis(Minga.LSP.SyncServer.Registry) != :undefined do
        :ets.delete(Minga.LSP.SyncServer.Registry, buffer)
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

      {:"$gen_cast", {:async_request, method, params, caller, ref}} ->
        send(parent, {:lsp_request, method, params, caller, ref})
        fake_lsp_client_loop(parent)

      _other ->
        fake_lsp_client_loop(parent)
    end
  end
end
