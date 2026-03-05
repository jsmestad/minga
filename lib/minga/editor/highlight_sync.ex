defmodule Minga.Editor.HighlightSync do
  @moduledoc """
  Synchronizes syntax highlighting between the editor and the Zig tree-sitter parser.

  Handles sending language/query/parse commands to Zig and processing
  highlight response events back into editor state.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Highlight
  alias Minga.Highlight.Grammar
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol

  @doc """
  Sets up highlighting for the current buffer.

  Detects the filetype, sends set_language + set_highlight_query + parse_buffer
  to the Zig port. Call this when a buffer is opened or switched to.
  """
  @spec setup_for_buffer(EditorState.t()) :: EditorState.t()
  def setup_for_buffer(%EditorState{buf: %{buffer: nil}} = state), do: state

  def setup_for_buffer(%EditorState{} = state) do
    filetype = BufferServer.filetype(state.buf.buffer)

    case Grammar.language_for_filetype(filetype) do
      {:ok, language} ->
        # Queries are pre-compiled in Zig at startup — just set language + parse
        send_parse_only(state, language)

      :unsupported ->
        %{state | highlight: Highlight.from_theme(state.theme)}
    end
  end

  @spec send_parse_only(EditorState.t(), String.t()) :: EditorState.t()
  defp send_parse_only(state, language) do
    version = state.highlight_version + 1
    content = BufferServer.content(state.buf.buffer)

    query_override = user_query_override(language)

    commands =
      [Protocol.encode_set_language(language) | query_override] ++
        [Protocol.encode_parse_buffer(version, content)]

    PortManager.send_commands(state.port_manager, commands)

    %{state | highlight: Highlight.from_theme(state.theme), highlight_version: version}
  end

  # Returns a list with a set_highlight_query command if the user has a custom
  # query file for this language, or an empty list to use the Zig built-in.
  @spec user_query_override(String.t()) :: [binary()]
  defp user_query_override(language) do
    user_path = user_query_path(language)

    if user_path != nil and File.exists?(user_path) do
      case File.read(user_path) do
        {:ok, query_text} -> [Protocol.encode_set_highlight_query(query_text)]
        {:error, _} -> []
      end
    else
      []
    end
  end

  @spec user_query_path(String.t()) :: String.t() | nil
  defp user_query_path(language) do
    case System.user_home() do
      nil -> nil
      home -> Path.join([home, ".config", "minga", "queries", language, "highlights.scm"])
    end
  end

  @doc """
  Sends a parse_buffer command for the current buffer content.

  Call this after content changes (insert, delete, paste, etc.).
  """
  @spec request_reparse(EditorState.t()) :: EditorState.t()
  def request_reparse(%EditorState{buf: %{buffer: nil}} = state), do: state

  def request_reparse(%EditorState{highlight: %{spans: []}} = state)
      when state.highlight.capture_names == [] do
    # No highlighting active — skip
    state
  end

  def request_reparse(%EditorState{} = state) do
    version = state.highlight_version + 1
    content = BufferServer.content(state.buf.buffer)

    PortManager.send_commands(state.port_manager, [
      Protocol.encode_parse_buffer(version, content)
    ])

    %{state | highlight_version: version}
  end

  @doc "Handles a highlight_names event from Zig."
  @spec handle_names(EditorState.t(), [String.t()]) :: EditorState.t()
  def handle_names(%EditorState{} = state, names) do
    %{state | highlight: Highlight.put_names(state.highlight, names)}
  end

  @doc "Handles a highlight_spans event from Zig."
  @spec handle_spans(EditorState.t(), non_neg_integer(), [Minga.Port.Protocol.highlight_span()]) ::
          EditorState.t()
  def handle_spans(%EditorState{} = state, version, spans) do
    %{state | highlight: Highlight.put_spans(state.highlight, version, spans)}
  end
end
