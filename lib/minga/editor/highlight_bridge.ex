defmodule Minga.Editor.HighlightBridge do
  @moduledoc """
  Bridges the editor with tree-sitter highlighting via the Zig port.

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
        already_loaded = MapSet.member?(state.highlight_languages_ready, language)

        if already_loaded do
          # Language + query already compiled on Zig side — just re-parse
          send_parse_only(state, language)
        else
          # First time for this language — send language + query + parse
          send_full_setup(state, language)
        end

      :unsupported ->
        %{state | highlight: Highlight.new()}
    end
  end

  @spec send_full_setup(EditorState.t(), String.t()) :: EditorState.t()
  defp send_full_setup(state, language) do
    case Grammar.read_query(language) do
      {:ok, query} ->
        version = state.highlight_version + 1
        content = BufferServer.content(state.buf.buffer)

        commands = [
          Protocol.encode_set_language(language),
          Protocol.encode_set_highlight_query(query),
          Protocol.encode_parse_buffer(version, content)
        ]

        PortManager.send_commands(state.port_manager, commands)

        %{
          state
          | highlight: Highlight.new(),
            highlight_version: version,
            highlight_languages_ready: MapSet.put(state.highlight_languages_ready, language)
        }

      {:error, _} ->
        %{state | highlight: Highlight.new()}
    end
  end

  @spec send_parse_only(EditorState.t(), String.t()) :: EditorState.t()
  defp send_parse_only(state, language) do
    version = state.highlight_version + 1
    content = BufferServer.content(state.buf.buffer)

    commands = [
      Protocol.encode_set_language(language),
      Protocol.encode_parse_buffer(version, content)
    ]

    PortManager.send_commands(state.port_manager, commands)

    %{state | highlight: Highlight.new(), highlight_version: version}
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
