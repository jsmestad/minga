defmodule Minga.Editor.HighlightSync do
  @moduledoc """
  Synchronizes syntax highlighting between the editor and the tree-sitter parser process.

  Handles sending language/query/parse commands to the parser and processing
  highlight response events back into editor state.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Highlight
  alias Minga.Highlight.Grammar
  alias Minga.Parser.Manager, as: ParserManager
  alias Minga.Port.Protocol

  @doc """
  Sets up highlighting for the current buffer.

  Detects the filetype, sends set_language + set_highlight_query + parse_buffer
  to the Zig port. Call this when a buffer is opened or switched to.
  """
  @spec setup_for_buffer(EditorState.t()) :: EditorState.t()
  def setup_for_buffer(%EditorState{buffers: %{active: nil}} = state), do: state

  def setup_for_buffer(%EditorState{} = state) do
    filetype = BufferServer.filetype(state.buffers.active)

    case Grammar.language_for_filetype(filetype) do
      {:ok, language} ->
        # Queries are pre-compiled in Zig at startup — just set language + parse
        Minga.Editor.log_to_messages("Syntax: #{language} (tree-sitter)")
        send_parse_only(state, language)

      :unsupported ->
        hl = state.highlight
        %{state | highlight: %{hl | current: Highlight.from_theme(state.theme)}}
    end
  end

  @spec send_parse_only(EditorState.t(), String.t()) :: EditorState.t()
  defp send_parse_only(state, language) do
    hl = state.highlight
    version = hl.version + 1
    content = BufferServer.content(state.buffers.active)

    query_override = user_query_override(language)
    injection_override = user_injection_query_override(language)
    fold_override = user_fold_query_override(language)
    textobject_override = user_textobject_query_override(language)

    parse_cmd = Protocol.encode_parse_buffer(version, content)

    commands =
      Enum.concat([
        [Protocol.encode_set_language(language)],
        query_override,
        injection_override,
        fold_override,
        textobject_override,
        [parse_cmd]
      ])

    ParserManager.send_commands(commands)

    %{state | highlight: %{hl | current: Highlight.from_theme(state.theme), version: version}}
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

  # Returns a list with a set_injection_query command if the user has a custom
  # injection query file for this language, or an empty list to use the Zig built-in.
  @spec user_injection_query_override(String.t()) :: [binary()]
  defp user_injection_query_override(language) do
    user_path = user_injection_query_path(language)

    if user_path != nil and File.exists?(user_path) do
      case File.read(user_path) do
        {:ok, query_text} -> [Protocol.encode_set_injection_query(query_text)]
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

  @spec user_injection_query_path(String.t()) :: String.t() | nil
  defp user_injection_query_path(language) do
    case System.user_home() do
      nil -> nil
      home -> Path.join([home, ".config", "minga", "queries", language, "injections.scm"])
    end
  end

  # Returns a list with a set_fold_query command if the user has a custom
  # fold query file for this language, or an empty list to use the Zig built-in.
  @spec user_fold_query_override(String.t()) :: [binary()]
  defp user_fold_query_override(language) do
    user_path = user_fold_query_path(language)

    if user_path != nil and File.exists?(user_path) do
      case File.read(user_path) do
        {:ok, query_text} -> [Protocol.encode_set_fold_query(query_text)]
        {:error, _} -> []
      end
    else
      []
    end
  end

  @spec user_fold_query_path(String.t()) :: String.t() | nil
  defp user_fold_query_path(language) do
    case System.user_home() do
      nil -> nil
      home -> Path.join([home, ".config", "minga", "queries", language, "folds.scm"])
    end
  end

  # Returns a list with a set_textobject_query command if the user has a custom
  # textobject query file for this language, or an empty list to use the Zig built-in.
  @spec user_textobject_query_override(String.t()) :: [binary()]
  defp user_textobject_query_override(language) do
    user_path = user_textobject_query_path(language)

    if user_path != nil and File.exists?(user_path) do
      case File.read(user_path) do
        {:ok, query_text} -> [Protocol.encode_set_textobject_query(query_text)]
        {:error, _} -> []
      end
    else
      []
    end
  end

  @spec user_textobject_query_path(String.t()) :: String.t() | nil
  defp user_textobject_query_path(language) do
    case System.user_home() do
      nil -> nil
      home -> Path.join([home, ".config", "minga", "queries", language, "textobjects.scm"])
    end
  end

  @doc """
  Sends a parse_buffer command for the current buffer content.

  Call this after content changes (insert, delete, paste, etc.).
  """
  @spec request_reparse(EditorState.t()) :: EditorState.t()
  def request_reparse(%EditorState{buffers: %{active: nil}} = state), do: state

  def request_reparse(
        %EditorState{highlight: %{current: %{spans: {}, capture_names: []}}} = state
      ) do
    # No highlighting active — skip
    state
  end

  def request_reparse(%EditorState{} = state) do
    hl = state.highlight
    version = hl.version + 1

    # Try incremental sync first: if the buffer has pending edit deltas,
    # send them as an edit_buffer command instead of the full content.
    edits = BufferServer.flush_edits(state.buffers.active)

    commands =
      if edits != [] do
        delta_maps = Enum.map(edits, &Map.from_struct/1)
        [Protocol.encode_edit_buffer(version, delta_maps)]
      else
        # No deltas (e.g., undo/redo, content replaced externally): full sync
        content = BufferServer.content(state.buffers.active)
        [Protocol.encode_parse_buffer(version, content)]
      end

    ParserManager.send_commands(commands)

    %{state | highlight: %{hl | version: version}}
  end

  @doc "Handles a highlight_names event from the parser."
  @spec handle_names(EditorState.t(), [String.t()]) :: EditorState.t()
  def handle_names(%EditorState{} = state, names) do
    hl = state.highlight
    %{state | highlight: %{hl | current: Highlight.put_names(hl.current, names)}}
  end

  @doc "Handles a highlight_spans event from Zig."
  @spec handle_spans(EditorState.t(), non_neg_integer(), [Minga.Port.Protocol.highlight_span()]) ::
          EditorState.t()
  def handle_spans(%EditorState{} = state, version, spans) do
    hl = state.highlight
    %{state | highlight: %{hl | current: Highlight.put_spans(hl.current, version, spans)}}
  end
end
