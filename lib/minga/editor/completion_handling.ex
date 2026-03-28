defmodule Minga.Editor.CompletionHandling do
  @moduledoc """
  Completion accept, filter, trigger, and dismiss logic.

  Handles both LSP completions (async, debounced) and config file
  completions (synchronous, from the Options registry). Extracted
  from `Minga.Editor` to keep the GenServer module focused on
  orchestration. All functions are pure state transforms.
  """

  alias Minga.Buffer
  alias Minga.Config
  alias Minga.Editing.Completion
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.SignatureHelp
  alias Minga.Editor.State, as: EditorState
  alias Minga.LSP.Client
  alias Minga.Workspace.State, as: WorkspaceState
  alias Minga.LSP.SyncServer

  @resolve_debounce_ms 150

  @doc """
  Triggers a `completionItem/resolve` request for the selected item.

  Called when C-n/C-p moves the selection. Debounces to avoid flooding
  the server when navigating rapidly. Only triggers if the selected
  item doesn't already have documentation and the server supports resolve.
  """
  @spec maybe_resolve_selected(EditorState.t()) :: EditorState.t()
  def maybe_resolve_selected(%{workspace: %{completion: nil}} = state), do: state

  def maybe_resolve_selected(%{workspace: %{completion: completion}} = state) do
    item = Completion.selected_item(completion)
    selected_idx = completion.selected

    # Skip if already resolved for this index, or if doc is already present
    if item == nil or selected_idx == completion.last_resolved_index or
         item.documentation != "" do
      state
    else
      # Cancel previous resolve timer
      if completion.resolve_timer do
        Process.cancel_timer(completion.resolve_timer)
      end

      timer =
        Process.send_after(self(), {:completion_resolve, selected_idx}, @resolve_debounce_ms)

      completion = %{completion | resolve_timer: timer}
      EditorState.update_workspace(state, &WorkspaceState.set_completion(&1, completion))
    end
  end

  @doc """
  Sends the actual `completionItem/resolve` request after debounce.

  Called from Editor.handle_info({:completion_resolve, index}).
  """
  @spec flush_resolve(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def flush_resolve(%{workspace: %{completion: nil}} = state, _index), do: state

  def flush_resolve(
        %{workspace: %{completion: completion, buffers: %{active: buf}}} = state,
        index
      ) do
    item = Enum.at(completion.filtered, index)

    if item == nil or item.raw == nil do
      state
    else
      case lsp_client_for(state, buf) do
        nil ->
          state

        client ->
          ref = Client.request(client, "completionItem/resolve", item.raw)

          put_in(
            state.workspace.lsp_pending,
            Map.put(state.workspace.lsp_pending, ref, :completion_resolve)
          )
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
  def handle_resolve_response(%{workspace: %{completion: nil}} = state, _result), do: state

  def handle_resolve_response(state, {:error, _error}), do: state

  def handle_resolve_response(%{workspace: %{completion: completion}} = state, {:ok, resolved}) do
    doc_text = extract_resolve_documentation(resolved)
    completion = Completion.update_selected_documentation(completion, doc_text)
    completion = %{completion | last_resolved_index: completion.selected}
    EditorState.update_workspace(state, &WorkspaceState.set_completion(&1, completion))
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
  @spec maybe_handle(EditorState.t(), boolean(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  def maybe_handle(state, was_inserting, codepoint, modifiers) do
    if Minga.Editing.inserting?(state) and was_inserting do
      maybe_update(state, codepoint, modifiers)
    else
      state = dismiss(state)
      # Dismiss signature help when leaving insert mode
      EditorState.update_shell_state(state, &%{&1 | signature_help: nil})
    end
  end

  @doc """
  Dismisses the active completion popup and resets trigger state.
  """
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(state) do
    # Cancel any pending resolve timer to avoid stale messages
    if state.workspace.completion && state.workspace.completion.resolve_timer do
      Process.cancel_timer(state.workspace.completion.resolve_timer)
    end

    new_bridge = CompletionTrigger.dismiss(state.workspace.completion_trigger)
    EditorState.update_workspace(state, &WorkspaceState.clear_completion(&1, new_bridge))
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec accept_text(EditorState.t(), Completion.t(), String.t()) :: EditorState.t()
  defp accept_text(%{workspace: %{buffers: %{active: buf}}} = state, completion, text)
       when is_pid(buf) do
    {trigger_line, trigger_col} = completion.trigger_position
    {_content, {cursor_line, cursor_col}} = Buffer.content_and_cursor(buf)

    if cursor_line == trigger_line and cursor_col > trigger_col do
      Buffer.apply_edit(buf, trigger_line, trigger_col, cursor_line, cursor_col, text)
    else
      Buffer.insert_text(buf, text)
    end

    # Buffer.Server now broadcasts :buffer_changed with delta from record_edit
    state
  end

  defp accept_text(state, _completion, _text), do: state

  @spec apply_text_edit(EditorState.t(), Completion.text_edit()) :: EditorState.t()
  defp apply_text_edit(%{workspace: %{buffers: %{active: buf}}} = state, edit) when is_pid(buf) do
    Buffer.apply_edit(
      buf,
      edit.range.start_line,
      edit.range.start_col,
      edit.range.end_line,
      edit.range.end_col,
      edit.new_text
    )

    # Buffer.Server now broadcasts :buffer_changed with delta from record_edit
    state
  end

  defp apply_text_edit(state, _edit), do: state

  @spec maybe_update(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  defp maybe_update(state, codepoint, _mods) do
    buf = state.workspace.buffers.active
    if buf == nil, do: state, else: do_update(state, buf, codepoint)
  end

  @spec do_update(EditorState.t(), pid(), non_neg_integer()) :: EditorState.t()
  defp do_update(state, buf, codepoint) do
    state = update_filter(state, buf)

    state =
      case config_completion_context(buf) do
        :none ->
          maybe_trigger(state, buf, codepoint)

        context ->
          maybe_trigger_config_completion(state, buf, context)
      end

    maybe_trigger_signature_help(state, buf, codepoint)
  end

  @spec update_filter(EditorState.t(), pid()) :: EditorState.t()
  defp update_filter(%{workspace: %{completion: nil}} = state, _buf), do: state

  defp update_filter(%{workspace: %{completion: %Completion{} = completion}} = state, buf) do
    prefix = completion_prefix(buf, completion.trigger_position)
    apply_filter(state, completion, prefix)
  end

  @spec apply_filter(EditorState.t(), Completion.t(), String.t() | nil) :: EditorState.t()
  defp apply_filter(state, _completion, nil), do: dismiss(state)
  defp apply_filter(state, _completion, ""), do: dismiss(state)

  defp apply_filter(state, completion, prefix) do
    filtered = Completion.filter(completion, prefix)

    if Completion.active?(filtered) do
      EditorState.update_workspace(state, &WorkspaceState.set_completion(&1, filtered))
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
          CompletionTrigger.maybe_trigger(state.workspace.completion_trigger, char, buf)

        EditorState.update_workspace(
          state,
          &WorkspaceState.set_completion_trigger(&1, new_bridge)
        )
    end
  end

  # ── Config file completion ──────────────────────────────────────────────

  @typedoc "Config completion context detected from cursor position."
  @type config_context :: :option_name | {:option_value, atom()} | :filetype | :none

  @doc false
  @spec config_completion_context(pid()) :: config_context()
  def config_completion_context(buf) do
    file_path = Buffer.file_path(buf)

    if config_file?(file_path) do
      {content, {cursor_line, cursor_col}} = Buffer.content_and_cursor(buf)
      lines = String.split(content, "\n")

      case Enum.at(lines, cursor_line) do
        nil -> :none
        line_text -> detect_config_context(line_text, cursor_col)
      end
    else
      :none
    end
  end

  @spec config_file?(String.t() | nil) :: boolean()
  defp config_file?(nil), do: false

  defp config_file?(path) do
    case Path.basename(path) do
      ".minga.exs" -> true
      "config.exs" -> matches_config_path?(path)
      _ -> false
    end
  end

  @spec matches_config_path?(String.t()) :: boolean()
  defp matches_config_path?(path) do
    config_path =
      try do
        Minga.Config.config_path()
      catch
        :exit, _ -> nil
      end

    config_path != nil and Path.expand(path) == Path.expand(config_path)
  end

  @doc """
  Detects the config DSL context from a line of text and cursor position.

  Returns `:option_name`, `{:option_value, atom()}`, `:filetype`, or `:none`.
  Used internally by `config_completion_context/1` after determining the
  buffer is a config file. Exposed for testing.
  """
  @spec detect_config_context(String.t(), non_neg_integer()) :: config_context()
  def detect_config_context(line_text, cursor_col) do
    before_cursor = String.slice(line_text, 0, cursor_col)
    trimmed = String.trim_leading(before_cursor)
    detect_from_trimmed(trimmed)
  end

  @spec detect_from_trimmed(String.t()) :: config_context()
  defp detect_from_trimmed("set " <> rest) do
    if String.contains?(rest, ",") do
      # Past the option name; check if we know this option for value completion
      case match_set_value_context("set " <> rest) do
        {:option_value, _} = ctx -> ctx
        nil -> :none
      end
    else
      detect_set_option_name("set " <> rest)
    end
  end

  defp detect_from_trimmed("for_filetype :" <> _), do: :filetype
  defp detect_from_trimmed(_), do: :none

  @spec detect_set_option_name(String.t()) :: config_context()
  defp detect_set_option_name("set :" <> _), do: :option_name
  defp detect_set_option_name(_), do: :none

  @spec match_set_value_context(String.t()) :: {:option_value, atom()} | nil
  defp match_set_value_context(text) do
    # Match: "set :option_name, " with optional value start
    case Regex.run(~r/^set\s+:([a-z_]+)\s*,\s*:?/, text) do
      [_full, name_str] ->
        name = String.to_existing_atom(name_str)

        if name in Config.valid_option_names() do
          {:option_value, name}
        else
          nil
        end

      nil ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec maybe_trigger_config_completion(EditorState.t(), pid(), active_config_context()) ::
          EditorState.t()
  defp maybe_trigger_config_completion(state, _buf, _context)
       when state.workspace.completion != nil do
    # Already showing a completion; update_filter handles narrowing.
    state
  end

  defp maybe_trigger_config_completion(state, buf, context) do
    case config_items_for_context(context) do
      [] -> state
      items -> build_config_completion(state, buf, items, context)
    end
  end

  @spec build_config_completion(
          EditorState.t(),
          pid(),
          [Completion.item()],
          active_config_context()
        ) :: EditorState.t()
  defp build_config_completion(state, buf, items, context) do
    {cursor_line, cursor_col} = Buffer.cursor(buf)
    trigger_col = config_trigger_col(buf, cursor_line, cursor_col, context)
    completion = Completion.new(items, {cursor_line, trigger_col})

    prefix = config_prefix(buf, cursor_line, trigger_col, cursor_col)
    completion = Completion.filter(completion, prefix)

    if Completion.active?(completion) do
      EditorState.update_workspace(state, &WorkspaceState.set_completion(&1, completion))
    else
      state
    end
  end

  @typedoc "Config contexts that produce completion items (excludes :none)."
  @type active_config_context :: :option_name | {:option_value, atom()} | :filetype

  @spec config_items_for_context(active_config_context()) :: [Completion.item()]
  defp config_items_for_context(:option_name), do: Config.option_name_completions()

  defp config_items_for_context({:option_value, name}),
    do: Config.option_value_completions(name)

  defp config_items_for_context(:filetype), do: Config.filetype_completions()

  @spec config_trigger_col(pid(), non_neg_integer(), non_neg_integer(), active_config_context()) ::
          non_neg_integer()
  defp config_trigger_col(buf, cursor_line, cursor_col, context) do
    {content, _cursor} = Buffer.content_and_cursor(buf)
    lines = String.split(content, "\n")
    line_text = Enum.at(lines, cursor_line) || ""
    before_cursor = String.slice(line_text, 0, cursor_col)

    case context do
      :option_name ->
        # Trigger after "set :" — find the colon
        case :binary.match(before_cursor, "set :") do
          {pos, 5} -> pos + 5
          :nomatch -> cursor_col
        end

      {:option_value, _} ->
        # Trigger after the ", " or ", :" — find the last comma+space
        case Regex.run(~r/,\s*:?/, before_cursor, return: :index) do
          [{pos, len} | _] -> pos + len
          nil -> cursor_col
        end

      :filetype ->
        # Trigger after "for_filetype :" — find the colon
        case :binary.match(before_cursor, "for_filetype :") do
          {pos, 14} -> pos + 14
          :nomatch -> cursor_col
        end
    end
  end

  @spec config_prefix(pid(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          String.t()
  defp config_prefix(buf, cursor_line, trigger_col, cursor_col) do
    if cursor_col > trigger_col do
      {content, _cursor} = Buffer.content_and_cursor(buf)
      lines = String.split(content, "\n")

      case Enum.at(lines, cursor_line) do
        nil -> ""
        line_text -> String.slice(line_text, trigger_col, cursor_col - trigger_col)
      end
    else
      ""
    end
  end

  @spec completion_prefix(pid(), {non_neg_integer(), non_neg_integer()}) :: String.t() | nil
  defp completion_prefix(buf, {trigger_line, trigger_col}) do
    {content, {cursor_line, cursor_col}} = Buffer.content_and_cursor(buf)

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
  def handle_response(%{workspace: %{buffers: %{active: nil}}} = state, _ref, _result), do: state

  def handle_response(state, ref, result) do
    buffer_pid = state.workspace.buffers.active

    {new_bridge, completion} =
      CompletionTrigger.handle_response(
        state.workspace.completion_trigger,
        ref,
        result,
        buffer_pid
      )

    new_state =
      EditorState.update_workspace(state, &WorkspaceState.set_completion_trigger(&1, new_bridge))

    case completion do
      nil ->
        new_state

      %Completion{} ->
        put_in(new_state.workspace.completion, completion)

      {:merge, items, trigger_pos} ->
        # Merge items from a secondary server into the existing completion
        merge_completion_items(new_state, items, trigger_pos)
    end
  end

  @spec merge_completion_items(
          EditorState.t(),
          [Completion.item()],
          {non_neg_integer(), non_neg_integer()}
        ) :: EditorState.t()
  defp merge_completion_items(state, [], _trigger_pos), do: state

  defp merge_completion_items(state, new_items, trigger_pos) do
    case state.workspace.completion do
      nil ->
        # No existing completion; create a new one from the merged items
        completion = Completion.new(new_items, trigger_pos)

        prefix =
          CompletionTrigger.get_typed_since_trigger(state.workspace.buffers.active, trigger_pos)

        completion = Completion.filter(completion, prefix)
        EditorState.update_workspace(state, &WorkspaceState.set_completion(&1, completion))

      %Completion{} = existing ->
        # Merge into existing completion
        merged_items = existing.items ++ new_items
        completion = Completion.new(merged_items, existing.trigger_position)

        prefix =
          CompletionTrigger.get_typed_since_trigger(
            state.workspace.buffers.active,
            existing.trigger_position
          )

        completion = Completion.filter(completion, prefix)
        EditorState.update_workspace(state, &WorkspaceState.set_completion(&1, completion))
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

  def handle_signature_help_response(state, {:ok, nil}),
    do: EditorState.update_shell_state(state, &%{&1 | signature_help: nil})

  def handle_signature_help_response(state, {:ok, result}) when is_map(result) do
    {cursor_row, cursor_col} = approximate_cursor_screen_pos(state)
    sh = SignatureHelp.from_response(result, cursor_row, cursor_col)
    EditorState.update_shell_state(state, &%{&1 | signature_help: sh})
  end

  def handle_signature_help_response(state, _), do: state

  @spec maybe_trigger_signature_help(EditorState.t(), pid(), non_neg_integer()) ::
          EditorState.t()
  defp maybe_trigger_signature_help(state, buf, codepoint) do
    char = codepoint_to_char(codepoint)

    cond do
      # ) always dismisses signature help
      codepoint == ?) ->
        EditorState.update_shell_state(state, &%{&1 | signature_help: nil})

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
        file_path = Buffer.file_path(buf)

        if file_path do
          uri = SyncServer.path_to_uri(file_path)
          {line, col} = Buffer.cursor(buf)

          params = %{
            "textDocument" => %{"uri" => uri},
            "position" => %{"line" => line, "character" => col}
          }

          ref = Client.request(client, "textDocument/signatureHelp", params)

          put_in(
            state.workspace.lsp_pending,
            Map.put(state.workspace.lsp_pending, ref, :signature_help)
          )
        else
          state
        end
    end
  end

  @spec approximate_cursor_screen_pos(EditorState.t()) ::
          {non_neg_integer(), non_neg_integer()}
  defp approximate_cursor_screen_pos(state) do
    buf = state.workspace.buffers.active

    if buf do
      {line, col} = Buffer.cursor(buf)
      vp = state.workspace.viewport
      screen_row = max(line - vp.top + 1, 1)
      screen_col = min(col + 4, vp.cols - 1)
      {screen_row, screen_col}
    else
      {div(state.workspace.viewport.rows, 2), div(state.workspace.viewport.cols, 2)}
    end
  end

  @spec lsp_client_for(EditorState.t(), pid()) :: pid() | nil
  defp lsp_client_for(_state, buffer_pid) do
    case SyncServer.clients_for_buffer(buffer_pid) do
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
