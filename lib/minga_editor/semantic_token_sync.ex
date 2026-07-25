defmodule MingaEditor.SemanticTokenSync do
  @moduledoc "Requests LSP semantic tokens, validates response identity, and stores accepted semantic layers."

  alias Minga.Buffer
  alias Minga.LSP.Client
  alias Minga.LSP.SemanticTokens
  alias Minga.LSP.SyncServer
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.LSP, as: LSPState

  @doc "Requests semantic tokens for the active buffer from the LSP server."
  @spec request_tokens(EditorState.t()) :: EditorState.t()
  def request_tokens(%EditorState{workspace: %{buffers: %{active: nil}}} = state), do: state

  def request_tokens(%EditorState{workspace: %{buffers: %{active: buffer}}} = state),
    do: request_tokens_for_buffer(state, buffer)

  @doc "Requests semantic tokens for a buffer and captures request-time identity."
  @spec request_tokens_for_buffer(EditorState.t(), pid()) :: EditorState.t()
  def request_tokens_for_buffer(%EditorState{} = state, buffer) when is_pid(buffer) do
    state = %{state | lsp: LSPState.clear_semantic_tokens(state.lsp, buffer)}

    with {:ok, path, version} <- buffer_request_identity(buffer),
         client when is_pid(client) <- current_client(buffer),
         {_types, _mods} = legend <- safe_legend(client),
         encoding when encoding in [:utf8, :utf16, :utf32] <- safe_encoding(client) do
      ref = Client.request_semantic_tokens(client, SyncServer.path_to_uri(path))

      %{
        state
        | lsp:
            LSPState.track_semantic_tokens_request(
              state.lsp,
              ref,
              client,
              buffer,
              version,
              encoding,
              legend
            )
      }
    else
      _ -> state
    end
  end

  @doc "Handles a semantic token response using captured request identity."
  @spec handle_response(
          EditorState.t(),
          pid(),
          pid(),
          non_neg_integer(),
          Minga.LSP.PositionEncoding.encoding(),
          {[String.t()], [String.t()]},
          {:ok, map()} | {:error, term()} | term()
        ) :: EditorState.t()
  def handle_response(state, _client, _buffer, _version, _encoding, _legend, {:error, _}),
    do: state

  def handle_response(state, _client, _buffer, _version, _encoding, _legend, {:ok, nil}),
    do: state

  def handle_response(
        state,
        client,
        buffer,
        version,
        encoding,
        {types, mods},
        {:ok, %{"data" => data}}
      )
      when is_list(data) do
    if valid_data?(data) and current_client(buffer) == client do
      accept_tokens(state, buffer, version, encoding, SemanticTokens.decode(data, types, mods))
    else
      state
    end
  end

  def handle_response(state, _client, _buffer, _version, _encoding, _legend, _other), do: state

  defp accept_tokens(state, buffer, version, encoding, tokens) do
    case safe_content_with_version(buffer) do
      {:ok, content, ^version} ->
        {names, name_to_id} = semantic_names(tokens)
        lines = String.split(content, "\n", trim: false)
        line_tuple = List.to_tuple(lines)

        spans =
          SemanticTokens.to_spans(
            tokens,
            build_line_offsets(lines),
            &Map.fetch!(name_to_id, &1),
            &line_text(line_tuple, &1),
            encoding
          )

        %{state | lsp: LSPState.accept_semantic_tokens(state.lsp, buffer, version, names, spans)}

      _ ->
        state
    end
  end

  defp semantic_names(tokens) do
    names =
      tokens
      |> Enum.map(&SemanticTokens.composite_capture_name(&1.type, &1.modifiers))
      |> Enum.uniq()

    {names, names |> Enum.with_index() |> Map.new()}
  end

  defp buffer_request_identity(buffer) do
    with path when is_binary(path) <- Buffer.file_path(buffer),
         version when is_integer(version) and version >= 0 <- Buffer.version(buffer) do
      {:ok, path, version}
    else
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  defp current_client(buffer) do
    case SyncServer.clients_for_buffer(buffer) do
      [client | _] when is_pid(client) -> client
      _ -> nil
    end
  end

  defp safe_legend(client) do
    Client.semantic_token_legend(client)
  catch
    :exit, _ -> nil
  end

  defp safe_encoding(client) do
    Client.encoding(client)
  catch
    :exit, _ -> nil
  end

  defp safe_content_with_version(buffer) do
    with {content, version} when is_binary(content) and is_integer(version) <-
           Buffer.content_with_version(buffer),
         do: {:ok, content, version}
  catch
    :exit, _ -> :error
  end

  defp valid_data?(data),
    do: rem(length(data), 5) == 0 and Enum.all?(data, &(is_integer(&1) and &1 >= 0))

  defp line_text(lines, line) when line < tuple_size(lines), do: elem(lines, line)
  defp line_text(_lines, _line), do: ""

  defp build_line_offsets(lines) do
    lines
    |> Enum.reduce({%{}, 0, 0}, fn line, {map, line_num, byte_offset} ->
      {Map.put(map, line_num, byte_offset), line_num + 1, byte_offset + byte_size(line) + 1}
    end)
    |> elem(0)
  end
end
