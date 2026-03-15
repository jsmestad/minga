defmodule Minga.Editor.CompletionHandling do
  @moduledoc """
  LSP completion accept, filter, trigger, and dismiss logic.

  Extracted from `Minga.Editor` to keep the GenServer module focused on
  orchestration. All functions are pure state transforms.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Completion
  alias Minga.Editor.BufferLifecycle
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.SignatureHelp
  alias Minga.Editor.State, as: EditorState
  alias Minga.LSP.Client

  @resolve_debounce_ms 150

  @doc """
  Triggers a `completionItem/resolve` request for the selected item.

  Called when C-n/C-p moves the selection. Debounces to avoid flooding
  the server when navigating rapidly. Only triggers if the selected
  item doesn't already have documentation and the server supports resolve.
  """
  @spec maybe_resolve_selected(EditorState.t()) :: EditorState.t()
  def maybe_resolve_selected(%{completion: nil} = state), do: state

  def maybe_resolve_selected(%{completion: completion} = state) do
    item = Completion.selected_item(completion)
    selected_idx = completion.selected

    # Skip if already resolved for this index, or if doc is already present
    if item == nil or selected_idx == completion.last_resolved_index or
         (item.documentation != "" and item.documentation != nil) do
      state
    else
      # Cancel previous resolve timer
      if completion.resolve_timer do
        Process.cancel_timer(completion.resolve_timer)
      end

      timer =
        Process.send_after(self(), {:completion_resolve, selected_idx}, @resolve_debounce_ms)

      completion = %{completion | resolve_timer: timer}
      %{state | completion: completion}
    end
  end

  @doc """
  Sends the actual `completionItem/resolve` request after debounce.

  Called from Editor.handle_info({:completion_resolve, index}).
  """
  @spec flush_resolve(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def flush_resolve(%{completion: nil} = state, _index), do: state

  def flush_resolve(%{completion: completion, buffers: %{active: buf}} = state, index) do
    item = Enum.at(completion.filtered, index)

    if item == nil or item.raw == nil do
      state
    else
      case lsp_client_for(state, buf) do
        nil ->
          state

        client ->
          ref = Client.request(client, "completionItem/resolve", item.raw)
          put_in(state.lsp.pending, Map.put(state.lsp.pending, ref, :completion_resolve))
      end
    end
  end

  @doc """
  Handles a `completionItem/resolve` response.

  Updates the selected completion item's documentation with the
  resolved content.
  """
  @spec handle_resolve_response(EditorState.t(), {:ok, term()} | {:error, term()}) ::
          EditorState.t()
  def handle_resolve_response(%{completion: nil} = state, _result), do: state

  def handle_resolve_response(state, {:error, _error}), do: state

  def handle_resolve_response(%{completion: completion} = state, {:ok, resolved}) do
    doc_text = extract_resolve_documentation(resolved)
    completion = Completion.update_selected_documentation(completion, doc_text)
    completion = %{completion | last_resolved_index: completion.selected}
    %{state | completion: completion}
  end

  @doc """
  Accepts the currently selected completion item.

  Routes to insert-text or text-edit depending on the completion type,
  then dismisses the completion popup.
  """
  @spec accept(EditorState.t(), Completion.t()) :: EditorState.t()
  def accept(state, completion) do
    case Completion.accept(completion) do
      nil ->
        dismiss(state)

      {:insert_text, text} ->
        state |> accept_text(completion, text) |> dismiss()

      {:text_edit, edit} ->
        state |> apply_text_edit(edit) |> dismiss()
    end
  end

  @doc """
  Updates or dismisses completion after a key press.

  Called after every key in insert mode. If the mode changed away from
  insert, dismisses completion. Otherwise updates the filter prefix
  and possibly triggers new completion.
  """
  @spec maybe_handle(EditorState.t(), atom(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  def maybe_handle(state, old_mode, codepoint, modifiers) do
    if state.vim.mode == :insert and old_mode == :insert do
      maybe_update(state, codepoint, modifiers)
    else
      state = dismiss(state)
      # Dismiss signature help when leaving insert mode
      %{state | signature_help: nil}
    end
  end

  @doc """
  Dismisses the active completion popup and resets trigger state.
  """
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(state) do
    # Cancel any pending resolve timer to avoid stale messages
    if state.completion && state.completion.resolve_timer do
      Process.cancel_timer(state.completion.resolve_timer)
    end

    new_bridge = CompletionTrigger.dismiss(state.completion_trigger)
    %{state | completion: nil, completion_trigger: new_bridge}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec accept_text(EditorState.t(), Completion.t(), String.t()) :: EditorState.t()
  defp accept_text(%{buffers: %{active: buf}} = state, completion, text)
       when is_pid(buf) do
    {trigger_line, trigger_col} = completion.trigger_position
    {_content, {cursor_line, cursor_col}} = BufferServer.content_and_cursor(buf)

    if cursor_line == trigger_line and cursor_col > trigger_col do
      BufferServer.apply_text_edit(buf, trigger_line, trigger_col, cursor_line, cursor_col, text)
    else
      BufferServer.insert_text(buf, text)
    end

    state |> BufferLifecycle.lsp_buffer_changed() |> BufferLifecycle.git_buffer_changed()
  end

  defp accept_text(state, _completion, _text), do: state

  @spec apply_text_edit(EditorState.t(), Completion.text_edit()) :: EditorState.t()
  defp apply_text_edit(%{buffers: %{active: buf}} = state, edit) when is_pid(buf) do
    BufferServer.apply_text_edit(
      buf,
      edit.range.start_line,
      edit.range.start_col,
      edit.range.end_line,
      edit.range.end_col,
      edit.new_text
    )

    state |> BufferLifecycle.lsp_buffer_changed() |> BufferLifecycle.git_buffer_changed()
  end

  defp apply_text_edit(state, _edit), do: state

  @spec maybe_update(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  defp maybe_update(state, codepoint, _mods) do
    buf = state.buffers.active
    if buf == nil, do: state, else: do_update(state, buf, codepoint)
  end

  @spec do_update(EditorState.t(), pid(), non_neg_integer()) :: EditorState.t()
  defp do_update(state, buf, codepoint) do
    state = update_filter(state, buf)
    state = maybe_trigger(state, buf, codepoint)
    maybe_trigger_signature_help(state, buf, codepoint)
  end

  @spec update_filter(EditorState.t(), pid()) :: EditorState.t()
  defp update_filter(%{completion: nil} = state, _buf), do: state

  defp update_filter(%{completion: %Completion{} = completion} = state, buf) do
    prefix = completion_prefix(buf, completion.trigger_position)
    apply_filter(state, completion, prefix)
  end

  @spec apply_filter(EditorState.t(), Completion.t(), String.t() | nil) :: EditorState.t()
  defp apply_filter(state, _completion, nil), do: dismiss(state)
  defp apply_filter(state, _completion, ""), do: dismiss(state)

  defp apply_filter(state, completion, prefix) do
    filtered = Completion.filter(completion, prefix)

    if Completion.active?(filtered) do
      %{state | completion: filtered}
    else
      dismiss(state)
    end
  end

  @spec maybe_trigger(EditorState.t(), pid(), non_neg_integer()) :: EditorState.t()
  defp maybe_trigger(state, buf, codepoint) do
    case codepoint_to_char(codepoint) do
      nil ->
        state

      char ->
        {new_bridge, _comp} =
          CompletionTrigger.maybe_trigger(state.completion_trigger, char, buf, state.lsp)

        %{state | completion_trigger: new_bridge}
    end
  end

  @spec completion_prefix(pid(), {non_neg_integer(), non_neg_integer()}) :: String.t() | nil
  defp completion_prefix(buf, {trigger_line, trigger_col}) do
    {content, {cursor_line, cursor_col}} = BufferServer.content_and_cursor(buf)

    if cursor_line == trigger_line and cursor_col >= trigger_col do
      lines = String.split(content, "\n")

      case Enum.at(lines, cursor_line) do
        nil -> nil
        line_text -> String.slice(line_text, trigger_col, cursor_col - trigger_col)
      end
    else
      nil
    end
  end

  @doc """
  Handles an LSP completion response.

  Matches the response ref against the pending trigger, creates a
  `Completion` struct if items were returned, and renders.
  """
  @spec handle_response(EditorState.t(), reference(), term()) :: EditorState.t()
  def handle_response(%{buffers: %{active: nil}} = state, _ref, _result), do: state

  def handle_response(state, ref, result) do
    buffer_pid = state.buffers.active

    {new_bridge, completion} =
      CompletionTrigger.handle_response(state.completion_trigger, ref, result, buffer_pid)

    new_state = %{state | completion_trigger: new_bridge}

    case completion do
      nil -> new_state
      %Completion{} -> %{new_state | completion: completion}
    end
  end

  @spec codepoint_to_char(non_neg_integer()) :: String.t() | nil
  defp codepoint_to_char(cp) when cp >= 32 and cp <= 0x10FFFF do
    <<cp::utf8>>
  rescue
    ArgumentError -> nil
  end

  defp codepoint_to_char(_), do: nil

  # ── Signature help ───────────────────────────────────────────────────────

  @doc """
  Handles a `textDocument/signatureHelp` response.

  Creates a `SignatureHelp` struct from the response and stores it
  in editor state. Returns state unchanged on error or empty response.
  """
  @spec handle_signature_help_response(EditorState.t(), {:ok, term()} | {:error, term()}) ::
          EditorState.t()
  def handle_signature_help_response(state, {:error, _}), do: state
  def handle_signature_help_response(state, {:ok, nil}), do: %{state | signature_help: nil}

  def handle_signature_help_response(state, {:ok, result}) when is_map(result) do
    {cursor_row, cursor_col} = approximate_cursor_screen_pos(state)
    sh = SignatureHelp.from_response(result, cursor_row, cursor_col)
    %{state | signature_help: sh}
  end

  def handle_signature_help_response(state, _), do: state

  @spec maybe_trigger_signature_help(EditorState.t(), pid(), non_neg_integer()) ::
          EditorState.t()
  defp maybe_trigger_signature_help(state, buf, codepoint) do
    char = codepoint_to_char(codepoint)

    cond do
      # ) always dismisses signature help
      codepoint == ?) ->
        %{state | signature_help: nil}

      # Check if the character is a server-declared signature trigger
      char != nil and signature_trigger_char?(state, buf, char) ->
        send_signature_help_request(state, buf)

      # Fallback: ( and , are universal signature triggers
      codepoint in [?(, ?,] ->
        send_signature_help_request(state, buf)

      true ->
        state
    end
  end

  @spec signature_trigger_char?(EditorState.t(), pid(), String.t()) :: boolean()
  defp signature_trigger_char?(state, buf, char) do
    client = lsp_client_for(state, buf)

    if client do
      caps = Client.capabilities(client)
      trigger_chars = get_in(caps, ["signatureHelpProvider", "triggerCharacters"]) || []
      char in trigger_chars
    else
      false
    end
  catch
    :exit, _ -> false
  end

  @spec send_signature_help_request(EditorState.t(), pid()) :: EditorState.t()
  defp send_signature_help_request(state, buf) do
    case lsp_client_for(state, buf) do
      nil ->
        state

      client ->
        file_path = BufferServer.file_path(buf)

        if file_path do
          uri = DocumentSync.path_to_uri(file_path)
          {line, col} = BufferServer.cursor(buf)

          params = %{
            "textDocument" => %{"uri" => uri},
            "position" => %{"line" => line, "character" => col}
          }

          ref = Client.request(client, "textDocument/signatureHelp", params)
          put_in(state.lsp.pending, Map.put(state.lsp.pending, ref, :signature_help))
        else
          state
        end
    end
  end

  @spec approximate_cursor_screen_pos(EditorState.t()) ::
          {non_neg_integer(), non_neg_integer()}
  defp approximate_cursor_screen_pos(state) do
    buf = state.buffers.active

    if buf do
      {line, col} = BufferServer.cursor(buf)
      vp = state.viewport
      screen_row = max(line - vp.top + 1, 1)
      screen_col = min(col + 4, vp.cols - 1)
      {screen_row, screen_col}
    else
      {div(state.viewport.rows, 2), div(state.viewport.cols, 2)}
    end
  end

  @spec lsp_client_for(EditorState.t(), pid()) :: pid() | nil
  defp lsp_client_for(state, buffer_pid) do
    case DocumentSync.clients_for_buffer(state.lsp, buffer_pid) do
      [client | _] -> client
      [] -> nil
    end
  end

  @spec extract_resolve_documentation(map()) :: String.t()
  defp extract_resolve_documentation(%{"documentation" => %{"value" => value}})
       when is_binary(value),
       do: String.trim(value)

  defp extract_resolve_documentation(%{"documentation" => doc}) when is_binary(doc),
    do: String.trim(doc)

  defp extract_resolve_documentation(_), do: ""
end
