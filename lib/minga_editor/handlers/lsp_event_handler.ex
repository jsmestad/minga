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

  def handle(%{shell_runtime: %{state: %ShellState{}}} = state, {:completion_debounce, gen}) do
    {new_bridge, facts} =
      CompletionTrigger.flush_debounce(
        MingaEditor.Shell.Traditional.ModalWorkflow.completion_trigger(state),
        gen
      )

    state =
      state
      |> MingaEditor.Shell.Traditional.ModalWorkflow.put_completion_trigger(new_bridge)
      |> CompletionHandling.install_completion_tracking(facts)

    {state, []}
  end

  def handle(state, {:completion_debounce, _gen}), do: {state, []}

  def handle(state, {:lsp_response, ref, result}) do
    case LSPState.take_pending_request(state.lsp, ref) do
      {:ok, request, lsp} ->
        state = %{state | lsp: lsp}
        {dispatch_pending_response(request, state, result), [:render_now]}

      :error ->
        {state, [:render_now]}
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

  def handle(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        {:completion_resolve, gen, raw_item}
      ) do
    {CompletionHandling.flush_resolve(state, gen, raw_item), []}
  end

  def handle(state, {:completion_resolve, _gen, _raw_item}), do: {state, []}

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

  @spec dispatch_pending_response(LSPState.pending_request(), EditorState.t(), term()) ::
          EditorState.t()
  defp dispatch_pending_response({:format, operation}, state, result) do
    FormatLifecycle.finish(operation)

    LspActions.handle_formatting_response(
      state,
      result,
      operation.buffer,
      operation.version,
      operation.encoding
    )
  end

  defp dispatch_pending_response(
         {:operation, kind, operation_id, origin_tab_id},
         state,
         result
       ) do
    dispatch_lsp_response({kind, operation_id, origin_tab_id}, state, result)
  end

  defp dispatch_pending_response(
         {:completion_result, role, client, buffer, version, gen, trigger_pos},
         state,
         result
       ) do
    CompletionHandling.handle_completion_result(
      state,
      role,
      client,
      buffer,
      version,
      gen,
      trigger_pos,
      result
    )
  end

  defp dispatch_pending_response(
         {:completion_resolve, client, buffer, version, gen, raw_item},
         state,
         result
       ) do
    if completion_resolve_current?(state, client, buffer, version, gen, raw_item),
      do: apply_completion_resolve_response(state, raw_item, result),
      else: state
  end

  defp dispatch_pending_response(
         {:signature_help, client, buffer, version, cursor},
         state,
         result
       ) do
    if signature_help_current?(state, client, buffer, version, cursor),
      do: apply_signature_help_response(state, result),
      else: state
  end

  defp dispatch_pending_response(
         {:response, kind, client, buffer, version, tab_id, cursor},
         state,
         result
       ) do
    if response_current?(state, client, buffer, version, tab_id, cursor),
      do: dispatch_current_response(kind, state, result, {client, buffer, version, tab_id}),
      else: state
  end

  defp dispatch_pending_response(
         {:inlay_hint, client, buffer, version, tab_id, viewport_top, viewport_rows},
         state,
         result
       ) do
    if response_current?(state, client, buffer, version, tab_id, nil) and
         inlay_viewport_current?(state, viewport_top, viewport_rows),
       do: dispatch_lsp_response(:inlay_hint, state, result),
       else: state
  end

  defp dispatch_pending_response(
         {:hover_mouse, _row, _col, _buffer, _line, _buffer_col, _version} = request,
         state,
         result
       ) do
    apply_traditional_lsp_response(request, state, result)
  end

  defp dispatch_pending_response({:semantic_tokens, buf_pid}, state, result) do
    SemanticTokenSync.handle_response(state, buf_pid, result)
  end

  @spec apply_completion_resolve_response(EditorState.t(), map(), term()) :: EditorState.t()
  defp apply_completion_resolve_response(
         %{shell_runtime: %{state: %ShellState{}}} = state,
         raw_item,
         result
       ),
       do: CompletionHandling.handle_resolve_response(state, raw_item, result)

  defp apply_completion_resolve_response(state, _raw_item, _result), do: state

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

  @spec dispatch_lsp_response(term(), EditorState.t(), term()) :: EditorState.t()
  defp dispatch_lsp_response(:definition, state, result),
    do: LspActions.handle_definition_response(state, result)

  defp dispatch_lsp_response(:peek_definition, state, result),
    do: LspActions.handle_peek_definition_response(state, result)

  defp dispatch_lsp_response(:hover, state, result),
    do: LspActions.handle_hover_response(state, result)

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

  defp dispatch_current_response(:hover, state, result, _origin),
    do: apply_traditional_lsp_response(:hover, state, result)

  defp dispatch_current_response(:code_lens, state, result, origin),
    do: LspActions.handle_code_lens_response(state, result, origin)

  defp dispatch_current_response(kind, state, result, _origin),
    do: dispatch_lsp_response(kind, state, result)

  @spec completion_resolve_current?(
          EditorState.t(),
          pid(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          map()
        ) :: boolean()
  defp completion_resolve_current?(state, client, buffer, version, gen, raw_item) do
    state.workspace.buffers.active == buffer and
      buffer_value(buffer, &Minga.Buffer.version/1) == version and
      match?([^client | _], Minga.LSP.SyncServer.clients_for_buffer(buffer)) and
      MingaEditor.Shell.Traditional.ModalWorkflow.completion_trigger(state)
      |> CompletionTrigger.generation()
      |> Kernel.==(gen) and
      completion_selected_raw?(state, raw_item)
  end

  @spec completion_selected_raw?(EditorState.t(), map()) :: boolean()
  defp completion_selected_raw?(%{shell_runtime: %{state: %ShellState{}}} = state, raw_item) do
    case MingaEditor.Shell.Traditional.ModalWorkflow.completion(state) do
      nil -> false
      completion -> Minga.Editing.Completion.selected_raw?(completion, raw_item)
    end
  end

  defp completion_selected_raw?(_state, _raw_item), do: false

  @spec signature_help_current?(
          EditorState.t(),
          pid(),
          pid(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()}
        ) :: boolean()
  defp signature_help_current?(state, client, buffer, version, cursor) do
    state.workspace.buffers.active == buffer and
      buffer_value(buffer, &Minga.Buffer.version/1) == version and
      match?([^client | _], Minga.LSP.SyncServer.clients_for_buffer(buffer)) and
      buffer_value(buffer, &Minga.Buffer.cursor/1) == cursor
  end

  defp response_current?(state, client, buffer, version, tab_id, cursor) do
    active_tab = MingaEditor.Shell.Runtime.active_tab(state.shell_runtime)

    tab_id == if(active_tab, do: active_tab.id) and state.workspace.buffers.active == buffer and
      match?([^client | _], Minga.LSP.SyncServer.clients_for_buffer(buffer)) and
      buffer_value(buffer, &Minga.Buffer.version/1) == version and
      (is_nil(cursor) or buffer_value(buffer, &Minga.Buffer.cursor/1) == cursor)
  end

  defp inlay_viewport_current?(state, top, rows) do
    viewport =
      MingaEditor.Session.State.current_viewport(
        state.workspace,
        state.frontend.terminal_viewport
      )

    viewport.top == top and viewport.rows == rows
  end

  defp buffer_value(buffer, fun) do
    fun.(buffer)
  catch
    :exit, _ -> :stale
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
