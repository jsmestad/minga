defmodule MingaEditor.Handlers.LspEventHandler do
  @moduledoc """
  Focused handler for Editor GenServer LSP and completion timer events.

  Extracts LSP response dispatch, completion debounce flushing, completion resolve flushing, and LSP debounce timers from the Editor GenServer into `handle/2` callbacks that return `{state, effects}`.
  """

  alias MingaEditor.CompletionHandling
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.LspActions
  alias MingaEditor.SemanticTokenSync
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.ModalOverlay

  @typedoc "Effects that the LSP event handler may return."
  @type lsp_effect :: :render_now

  @doc """
  Dispatches an LSP or completion event to the appropriate handler.

  Returns `{state, effects}` where effects encode Editor-owned side effects such as rendering.
  """
  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [lsp_effect()]}

  def handle(state, {:completion_debounce, clients, buffer_pid}) do
    new_bridge =
      CompletionTrigger.flush_debounce(
        ModalOverlay.completion_trigger(state),
        clients,
        buffer_pid
      )

    {ModalOverlay.put_completion_trigger(state, new_bridge), []}
  end

  def handle(state, {:lsp_response, ref, result}) do
    dispatch_tracked_response(state, ref, result, Map.fetch(state.workspace.lsp_pending, ref))
  end

  def handle(state, :inlay_hint_scroll_debounce) do
    state = EditorState.update_lsp(state, &LSPState.clear_inlay_hint_timer/1)
    {LspActions.inlay_hints(state), []}
  end

  def handle(state, :document_highlight_debounce) do
    state = EditorState.update_lsp(state, &LSPState.clear_highlight_timer/1)
    {LspActions.document_highlight(state), []}
  end

  def handle(state, {:completion_resolve, index}) do
    {CompletionHandling.flush_resolve(state, index), []}
  end

  def handle(state, :request_code_lens_and_inlay_hints) do
    state = LspActions.code_lens(state)
    {LspActions.inlay_hints(state), []}
  end

  def handle(state, _msg), do: {state, []}

  @spec dispatch_tracked_response(EditorState.t(), reference(), term(), {:ok, term()} | :error) ::
          {EditorState.t(), [lsp_effect()]}
  defp dispatch_tracked_response(state, ref, result, {:ok, :completion_resolve}) do
    state = delete_lsp_pending(state, ref)
    {CompletionHandling.handle_resolve_response(state, result), [:render_now]}
  end

  defp dispatch_tracked_response(state, ref, result, {:ok, :signature_help}) do
    state = delete_lsp_pending(state, ref)
    {CompletionHandling.handle_signature_help_response(state, result), [:render_now]}
  end

  defp dispatch_tracked_response(state, ref, result, {:ok, {:semantic_tokens, buf_pid}}) do
    state = delete_lsp_pending(state, ref)
    {SemanticTokenSync.handle_response(state, buf_pid, result), [:render_now]}
  end

  defp dispatch_tracked_response(state, ref, result, {:ok, kind}) when is_atom(kind) do
    state = delete_lsp_pending(state, ref)
    {dispatch_lsp_response(kind, state, result), [:render_now]}
  end

  defp dispatch_tracked_response(state, ref, result, {:ok, kind}) when is_tuple(kind) do
    state = delete_lsp_pending(state, ref)
    {dispatch_lsp_response(kind, state, result), [:render_now]}
  end

  defp dispatch_tracked_response(state, ref, result, :error) do
    {CompletionHandling.handle_response(state, ref, result), [:render_now]}
  end

  @spec set_lsp_pending(EditorState.t(), %{reference() => atom() | tuple()}) :: EditorState.t()
  defp set_lsp_pending(state, pending) do
    EditorState.update_workspace(state, &SessionState.set_lsp_pending(&1, pending))
  end

  @spec delete_lsp_pending(EditorState.t(), reference()) :: EditorState.t()
  defp delete_lsp_pending(state, ref) do
    set_lsp_pending(state, Map.delete(state.workspace.lsp_pending, ref))
  end

  @spec dispatch_lsp_response(term(), EditorState.t(), term()) :: EditorState.t()
  defp dispatch_lsp_response(:definition, state, result),
    do: LspActions.handle_definition_response(state, result)

  defp dispatch_lsp_response(:peek_definition, state, result),
    do: LspActions.handle_peek_definition_response(state, result)

  defp dispatch_lsp_response(:hover, state, result),
    do: LspActions.handle_hover_response(state, result)

  defp dispatch_lsp_response({:hover_mouse, row, col}, state, result),
    do: LspActions.handle_hover_mouse_response(state, result, row, col)

  defp dispatch_lsp_response(:references, state, result),
    do: LspActions.handle_references_response(state, result)

  defp dispatch_lsp_response(:document_highlight, state, result),
    do: LspActions.handle_document_highlight_response(state, result)

  defp dispatch_lsp_response(:code_action, state, result),
    do: LspActions.handle_code_action_response(state, result)

  defp dispatch_lsp_response(:prepare_rename, state, result),
    do: LspActions.handle_prepare_rename_response(state, result)

  defp dispatch_lsp_response(:rename, state, result),
    do: LspActions.handle_rename_response(state, result)

  defp dispatch_lsp_response(:type_definition, state, result),
    do: LspActions.handle_type_definition_response(state, result)

  defp dispatch_lsp_response(:implementation, state, result),
    do: LspActions.handle_implementation_response(state, result)

  defp dispatch_lsp_response(:document_symbol, state, result),
    do: LspActions.handle_document_symbol_response(state, result)

  defp dispatch_lsp_response(:workspace_symbol, state, result),
    do: LspActions.handle_workspace_symbol_response(state, result)

  defp dispatch_lsp_response(:selection_range, state, result),
    do: LspActions.handle_selection_range_response(state, result)

  defp dispatch_lsp_response(:prepare_call_hierarchy, state, result),
    do: LspActions.handle_prepare_call_hierarchy_response(state, result)

  defp dispatch_lsp_response(:incoming_calls, state, result),
    do: LspActions.handle_incoming_calls_response(state, result)

  defp dispatch_lsp_response(:outgoing_calls, state, result),
    do: LspActions.handle_outgoing_calls_response(state, result)

  defp dispatch_lsp_response(:prepare_outgoing_hierarchy, state, result),
    do: LspActions.handle_prepare_outgoing_hierarchy_response(state, result)

  defp dispatch_lsp_response(:code_lens, state, result),
    do: LspActions.handle_code_lens_response(state, result)

  defp dispatch_lsp_response(:code_lens_resolve, state, result),
    do: LspActions.handle_code_lens_resolve_response(state, result)

  defp dispatch_lsp_response(:inlay_hint, state, result),
    do: LspActions.handle_inlay_hint_response(state, result)

  defp dispatch_lsp_response(kind, state, _result) do
    Minga.Log.debug(:lsp, "Unhandled LSP response kind: #{inspect(kind)}")
    state
  end
end
