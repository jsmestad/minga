defmodule MingaEditor.Handlers.LspEventHandler do
  @moduledoc """
  Owns Editor-side LSP, completion, and formatting response actions.

  `dispatch/2` applies tracked state and then renders in handler order. Request
  references, operation ids, tab ids, and formatting refs reject stale replies
  before mutation. LSP clients and format workers retain their existing OTP
  supervision; debounce timers are created by the Editor-side request owners
  and received here by the same Editor process. Timeouts cancel the tracked
  format operation, unknown replies are ignored or logged, and terminal
  rendering happens only after response handling completes.
  """

  alias MingaEditor.CompletionHandling
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.LSP.FormatLifecycle
  alias MingaEditor.LspActions
  alias MingaEditor.SemanticTokenSync
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.OperationFeedback

  @typedoc "Effects that the LSP event handler may return."
  @type lsp_effect :: :render_now

  @doc "Applies one LSP/completion message and its focused render action."
  @spec dispatch(EditorState.t(), term()) :: EditorState.t()
  def dispatch(%EditorState{} = state, message) do
    {state, effects} = handle(state, message)
    apply_effects(state, effects)
  end

  @doc """
  Dispatches an LSP or completion event to the appropriate handler.

  Returns `{state, effects}` where effects encode Editor-owned side effects such as rendering.
  """
  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [lsp_effect()]}

  def handle(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        {:completion_debounce, clients, buffer_pid}
      ) do
    new_bridge =
      CompletionTrigger.flush_debounce(
        MingaEditor.Shell.Traditional.ModalWorkflow.completion_trigger(state),
        clients,
        buffer_pid
      )

    {MingaEditor.Shell.Traditional.ModalWorkflow.put_completion_trigger(state, new_bridge), []}
  end

  def handle(state, {:completion_debounce, _clients, _buffer_pid}), do: {state, []}

  def handle(state, {:lsp_response, ref, result}) do
    case LSPState.fetch_format(state.lsp, ref) do
      {:ok, _operation} ->
        dispatch_format_response(state, ref, result)

      :error ->
        dispatch_operation_response(state, ref, result)
    end
  end

  def handle(state, :inlay_hint_scroll_debounce) do
    state = %{state | lsp: (&LSPState.clear_inlay_hint_timer/1).(state.lsp)}
    {LspActions.inlay_hints(state), []}
  end

  def handle(state, :document_highlight_debounce) do
    state = %{state | lsp: (&LSPState.clear_highlight_timer/1).(state.lsp)}
    {LspActions.document_highlight(state), []}
  end

  def handle(%{shell_runtime: %{state: %ShellState{}}} = state, {:completion_resolve, index}) do
    {CompletionHandling.flush_resolve(state, index), []}
  end

  def handle(state, {:completion_resolve, _index}), do: {state, []}

  def handle(state, :request_code_lens_and_inlay_hints) do
    state = LspActions.code_lens(state)
    {LspActions.inlay_hints(state), []}
  end

  def handle(state, {:lsp_format_spinner, ref}) do
    if LSPState.format_active?(state.lsp, ref) do
      {NoticeWorkflow.publish(state, "Formatting…"), [:render_now]}
    else
      {state, []}
    end
  end

  def handle(state, {:lsp_format_cancellable, ref}) do
    if LSPState.format_active?(state.lsp, ref) do
      {NoticeWorkflow.publish(state, "Formatting… [Esc to cancel]"), [:render_now]}
    else
      {state, []}
    end
  end

  def handle(state, {:lsp_format_timeout, ref}) do
    case LSPState.fetch_format(state.lsp, ref) do
      :error ->
        {state, []}

      {:ok, operation} ->
        state = %{state | lsp: (&LSPState.drop_format(&1, ref)).(state.lsp)}
        FormatLifecycle.cancel(operation)
        {NoticeWorkflow.publish(state, "Format timed out [r to retry]"), [:render_now]}
    end
  end

  def handle(state, _msg), do: {state, []}

  @spec apply_effects(EditorState.t(), [lsp_effect()]) :: EditorState.t()
  defp apply_effects(state, []), do: state

  defp apply_effects(state, [:render_now | rest]) do
    state = MingaEditor.Renderer.render_or_async(state)
    apply_effects(state, rest)
  end

  @spec dispatch_format_response(EditorState.t(), reference(), term()) ::
          {EditorState.t(), [lsp_effect()]}
  defp dispatch_format_response(state, ref, result) do
    case LSPState.fetch_format(state.lsp, ref) do
      :error ->
        {state, []}

      {:ok, operation} ->
        state = %{state | lsp: (&LSPState.drop_format(&1, ref)).(state.lsp)}
        FormatLifecycle.finish(operation)

        state =
          LspActions.handle_formatting_response(
            state,
            result,
            operation.buffer,
            operation.version,
            operation.encoding
          )

        {state, [:render_now]}
    end
  end

  @spec dispatch_operation_response(EditorState.t(), reference(), term()) ::
          {EditorState.t(), [lsp_effect()]}
  defp dispatch_operation_response(state, ref, result) do
    case LSPState.take_operation_request(state.lsp, ref) do
      {:ok, request, lsp} ->
        state = %{state | lsp: (fn _current -> lsp end).(state.lsp)}
        {dispatch_lsp_response(request, state, result), [:render_now]}

      :error ->
        dispatch_tracked_response(state, ref, result, Map.fetch(state.workspace.lsp_pending, ref))
    end
  end

  @spec dispatch_tracked_response(EditorState.t(), reference(), term(), {:ok, term()} | :error) ::
          {EditorState.t(), [lsp_effect()]}
  defp dispatch_tracked_response(state, ref, result, {:ok, :completion_resolve}) do
    state = delete_lsp_pending(state, ref)
    {apply_completion_resolve_response(state, result), [:render_now]}
  end

  defp dispatch_tracked_response(state, ref, result, {:ok, :signature_help}) do
    state = delete_lsp_pending(state, ref)
    {apply_signature_help_response(state, result), [:render_now]}
  end

  defp dispatch_tracked_response(state, ref, result, {:ok, :hover}) do
    state = delete_lsp_pending(state, ref)
    {apply_traditional_lsp_response(:hover, state, result), [:render_now]}
  end

  defp dispatch_tracked_response(state, ref, result, {:ok, {:hover_mouse, _, _} = kind}) do
    state = delete_lsp_pending(state, ref)
    {apply_traditional_lsp_response(kind, state, result), [:render_now]}
  end

  defp dispatch_tracked_response(
         state,
         ref,
         result,
         {:ok, {:hover_mouse, _, _, _, _, _, _, _} = kind}
       ) do
    state = delete_lsp_pending(state, ref)
    {apply_traditional_lsp_response(kind, state, result), [:render_now]}
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

  @spec apply_completion_resolve_response(EditorState.t(), term()) :: EditorState.t()
  defp apply_completion_resolve_response(
         %{shell_runtime: %{state: %ShellState{}}} = state,
         result
       ),
       do: CompletionHandling.handle_resolve_response(state, result)

  defp apply_completion_resolve_response(state, _result), do: state

  @spec apply_signature_help_response(EditorState.t(), term()) :: EditorState.t()
  defp apply_signature_help_response(%{shell_runtime: %{state: %ShellState{}}} = state, result),
    do: CompletionHandling.handle_signature_help_response(state, result)

  defp apply_signature_help_response(state, _result), do: state

  @spec apply_traditional_lsp_response(term(), EditorState.t(), term()) :: EditorState.t()
  defp apply_traditional_lsp_response(
         kind,
         %{shell_runtime: %{state: %ShellState{}}} = state,
         result
       ),
       do: dispatch_lsp_response(kind, state, result)

  defp apply_traditional_lsp_response(_kind, state, _result), do: state

  @spec delete_lsp_pending(EditorState.t(), reference()) :: EditorState.t()
  defp delete_lsp_pending(state, ref) do
    %{state | workspace: MingaEditor.Session.State.delete_lsp_pending(state.workspace, ref)}
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

  defp dispatch_lsp_response(
         {:hover_mouse, row, col, buffer, line, buffer_col, version},
         state,
         result
       ),
       do:
         LspActions.handle_hover_mouse_response(
           state,
           result,
           row,
           col,
           buffer,
           line,
           buffer_col,
           version
         )

  defp dispatch_lsp_response({kind, operation_id, origin_tab_id}, state, result)
       when kind in [:references, :rename] do
    {state, active_tab} = MingaEditor.Shell.Workflow.resolve_active_tab(state)

    if operation_response_current?(origin_tab_id, active_tab) do
      dispatch_lsp_response({kind, operation_id}, state, result)
    else
      %{
        state
        | feedback:
            Feedback.accept_operation_feedback(
              state.feedback,
              OperationFeedback.finish(
                state.feedback.operation_feedback,
                operation_id,
                :stale,
                operation_tab_changed_message(kind)
              )
            )
      }
    end
  end

  defp dispatch_lsp_response({:references, operation_id}, state, result),
    do: LspActions.handle_references_response(state, result, operation_id)

  defp dispatch_lsp_response(:document_highlight, state, result),
    do: LspActions.handle_document_highlight_response(state, result)

  defp dispatch_lsp_response(:code_action, state, result),
    do: LspActions.handle_code_action_response(state, result)

  defp dispatch_lsp_response(:prepare_rename, state, result),
    do: LspActions.handle_prepare_rename_response(state, result)

  defp dispatch_lsp_response({:rename, operation_id}, state, result),
    do: LspActions.handle_rename_response(state, result, operation_id)

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

  @spec operation_response_current?(
          MingaEditor.State.Tab.id() | nil,
          MingaEditor.State.Tab.t() | nil
        ) :: boolean()
  defp operation_response_current?(nil, nil), do: true
  defp operation_response_current?(tab_id, %{id: tab_id}), do: true
  defp operation_response_current?(_origin_tab_id, _active_tab), do: false

  @spec operation_tab_changed_message(:references | :rename) :: String.t()
  defp operation_tab_changed_message(:references),
    do: "References response ignored after tab switch"

  defp operation_tab_changed_message(:rename), do: "Rename response ignored after tab switch"
end
