defmodule MingaEditor.SemanticTokenSync do
  @moduledoc """
  Synchronizes LSP semantic tokens with the highlight pipeline.

  Requests semantic tokens from the LSP server for the active buffer,
  decodes the response, and merges the resulting spans into the
  Highlight struct so they participate in the innermost-wins sweep
  at layer 2 (above tree-sitter).

  ## Lifecycle

  1. When a buffer opens or changes, `request_tokens/1` sends
     `textDocument/semanticTokens/full` to the LSP server.
  2. The response arrives as `{:lsp_response, ref, result}`.
  3. `handle_response/2` decodes the delta-encoded tokens and merges
     them into the buffer's Highlight state.
  4. The next render frame picks up the updated spans.

  ## Integration with highlight sweep

  Semantic token spans are stored alongside tree-sitter spans in the
  Highlight struct. The sweep's `(layer DESC, width ASC, pattern_index DESC)`
  priority ensures semantic tokens (layer 2) override tree-sitter (layer 0)
  and injections (layer 1) when they overlap.
  """

  alias Minga.Buffer
  alias MingaEditor.State, as: EditorState
  alias Minga.LSP.Client
  alias MingaEditor.Workspace.State, as: WorkspaceState
  alias Minga.LSP.SemanticTokens
  alias MingaEditor.UI.Highlight

  @doc """
  Requests semantic tokens for the active buffer from the LSP server.

  Returns the updated state with the request tracked in `lsp_pending`.
  Does nothing if no LSP client is available or the server doesn't
  support semantic tokens.
  """
  @spec request_tokens(EditorState.t()) :: EditorState.t()
  def request_tokens(%EditorState{workspace: %{buffers: %{active: nil}}} = state), do: state

  def request_tokens(%EditorState{} = state) do
    buf_pid = state.workspace.buffers.active
    file_path = Buffer.file_path(buf_pid)

    with true <- is_binary(file_path),
         client when is_pid(client) <- find_lsp_client(state, buf_pid),
         {_types, _mods} <- safe_legend(client) do
      uri = "file://#{file_path}"
      ref = Client.request_semantic_tokens(client, uri)
      pending = Map.put(state.workspace.lsp_pending, ref, {:semantic_tokens, buf_pid})
      EditorState.update_workspace(state, &WorkspaceState.set_lsp_pending(&1, pending))
    else
      _ -> state
    end
  end

  @doc """
  Handles a semantic token response from the LSP server.

  Decodes the delta-encoded token data and merges the resulting spans
  into the buffer's Highlight state. The capture names for semantic
  token types are dynamically added to the Highlight struct.
  """
  @spec handle_response(EditorState.t(), pid(), {:ok, map()} | {:error, term()}) ::
          EditorState.t()
  def handle_response(state, _buf_pid, {:error, _error}), do: state
  def handle_response(state, _buf_pid, {:ok, nil}), do: state

  def handle_response(state, buf_pid, {:ok, %{"data" => data}}) when is_list(data) do
    client = find_lsp_client(state, buf_pid)

    case safe_legend(client) do
      {token_types, token_modifiers} ->
        tokens = SemanticTokens.decode(data, token_types, token_modifiers)
        merge_tokens(state, buf_pid, tokens)

      _ ->
        state
    end
  end

  def handle_response(state, _buf_pid, _other), do: state

  # ── Private ──────────────────────────────────────────────────────────

  @spec merge_tokens(EditorState.t(), pid(), [SemanticTokens.token()]) :: EditorState.t()
  defp merge_tokens(state, buf_pid, tokens) do
    hl = Map.get(state.workspace.highlight.highlights, buf_pid)

    if hl == nil do
      state
    else
      # Build capture name → ID mapping, adding new names as needed
      {hl, name_to_id} = ensure_capture_names(hl, tokens)

      # Build line byte offset map from buffer content
      content = Buffer.content(buf_pid)
      line_byte_offsets = build_line_offsets(content)

      # Get line text lookup
      lines = String.split(content, "\n", trim: false)
      line_text_fn = fn line_num -> Enum.at(lines, line_num, "") end

      # Get encoding from LSP client
      encoding = get_encoding(state, buf_pid)

      # Convert tokens to spans
      spans =
        SemanticTokens.to_spans(
          tokens,
          line_byte_offsets,
          fn name -> Map.get(name_to_id, name, 0) end,
          line_text_fn,
          encoding
        )

      # Merge semantic spans with existing tree-sitter spans
      existing_spans = normalize_spans(hl.spans)

      # Filter out old semantic token spans (layer 2) before merging new ones
      ts_spans = Enum.reject(existing_spans, fn s -> Map.get(s, :layer, 0) == 2 end)
      merged = ts_spans ++ spans

      hl = %{hl | spans: List.to_tuple(merged)}

      highlights = Map.put(state.workspace.highlight.highlights, buf_pid, hl)
      put_in(state.workspace.highlight.highlights, highlights)
    end
  end

  @spec ensure_capture_names(Highlight.t(), [SemanticTokens.token()]) ::
          {Highlight.t(), %{String.t() => non_neg_integer()}}
  defp ensure_capture_names(hl, tokens) do
    # Collect all composite capture names needed by tokens
    needed_names =
      tokens
      |> Enum.map(fn token ->
        SemanticTokens.composite_capture_name(token.type, token.modifiers)
      end)
      |> Enum.uniq()

    # Build a map of existing names (capture_names is a tuple)
    existing_list = Tuple.to_list(hl.capture_names)
    existing_map = existing_list |> Enum.with_index() |> Map.new()

    # Add any missing names
    {new_list, name_map} =
      Enum.reduce(needed_names, {existing_list, existing_map}, fn name, {names, map} ->
        if Map.has_key?(map, name) do
          {names, map}
        else
          idx = length(names)
          {names ++ [name], Map.put(map, name, idx)}
        end
      end)

    hl = %{hl | capture_names: List.to_tuple(new_list)}
    {hl, name_map}
  end

  @spec build_line_offsets(String.t()) :: %{non_neg_integer() => non_neg_integer()}
  defp build_line_offsets(content) do
    content
    |> String.split("\n", trim: false)
    |> Enum.reduce({%{}, 0, 0}, fn line, {map, line_num, byte_offset} ->
      map = Map.put(map, line_num, byte_offset)
      {map, line_num + 1, byte_offset + byte_size(line) + 1}
    end)
    |> elem(0)
  end

  @spec normalize_spans(tuple() | [map()]) :: [map()]
  defp normalize_spans(spans) when is_tuple(spans), do: Tuple.to_list(spans)
  defp normalize_spans(spans) when is_list(spans), do: spans

  @spec find_lsp_client(EditorState.t(), pid()) :: pid() | nil
  defp find_lsp_client(state, buf_pid) do
    case Map.get(state, :lsp_clients, %{}) do
      clients when is_map(clients) ->
        filetype = Buffer.filetype(buf_pid)
        Map.get(clients, filetype)

      _ ->
        nil
    end
  end

  @spec get_encoding(EditorState.t(), pid()) :: Minga.LSP.PositionEncoding.encoding()
  defp get_encoding(state, buf_pid) do
    case find_lsp_client(state, buf_pid) do
      nil -> :utf16
      client -> safe_encoding(client)
    end
  end

  @spec safe_legend(pid() | nil) :: {[String.t()], [String.t()]} | nil
  defp safe_legend(nil), do: nil

  defp safe_legend(client) do
    Client.semantic_token_legend(client)
  catch
    :exit, _ -> nil
  end

  @spec safe_encoding(pid()) :: Minga.LSP.PositionEncoding.encoding()
  defp safe_encoding(client) do
    Client.encoding(client)
  catch
    :exit, _ -> :utf16
  end
end
