defmodule MingaEditor.HighlightSync do
  @moduledoc """
  Synchronizes syntax highlighting between the editor and the tree-sitter parser process.

  Handles sending language/query/parse commands to the parser and processing
  highlight response events back into editor state.
  """

  alias Minga.Buffer
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.Frontend.Protocol
  alias Minga.Parser.Manager, as: ParserManager
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.Highlight.Grammar
  alias MingaEditor.Window

  @doc """
  Sets up highlighting for the current buffer.

  Detects the filetype, sends set_language + set_highlight_query + parse_buffer
  to the Zig port. Call this when a buffer is opened or switched to.
  """
  @spec setup_for_buffer(EditorState.t()) :: EditorState.t()
  def setup_for_buffer(%EditorState{workspace: %{buffers: %{active: nil}}} = state), do: state

  def setup_for_buffer(%EditorState{} = state) do
    filetype = Buffer.filetype(state.workspace.buffers.active)

    case Grammar.language_for_filetype(filetype) do
      {:ok, language} ->
        # Queries are pre-compiled in Zig at startup — just set language + parse
        Minga.Log.info(:editor, "Syntax: #{language} (tree-sitter)")
        send_parse_only(state, language)

      :unsupported ->
        state
        |> put_active_highlight(Highlight.from_theme(state.theme))
        |> clear_active_document_symbols()
    end
  end

  @typedoc "Options for `setup_for_buffer_pid/3`."
  @type setup_opt :: {:syntax, MingaEditor.UI.Theme.syntax()}

  @doc """
  Sets up highlighting for a specific buffer PID that may not be the active buffer.

  Used for non-active buffers that need tree-sitter parsing even when they're not the focused buffer. Assigns a buffer_id, sends set_language + parse_buffer to the parser, and initializes the highlight entry.

  ## Options

    * `:syntax` — custom syntax theme map to use instead of the global theme's syntax.
  """
  @spec setup_for_buffer_pid(EditorState.t(), pid(), [setup_opt()]) :: EditorState.t()
  def setup_for_buffer_pid(state, buf_pid, opts \\ [])

  def setup_for_buffer_pid(%EditorState{} = state, buf_pid, opts) when is_pid(buf_pid) do
    filetype = Buffer.filetype(buf_pid)

    case Grammar.language_for_filetype(filetype) do
      {:ok, language} ->
        send_parse_for_pid(state, buf_pid, language, opts)

      :unsupported ->
        state
    end
  end

  @doc """
  Requests a full reparse of a specific buffer PID.

  Used after content changes to non-active buffers. Sends a parse_buffer command with the full content since replace_generated_content clears pending edit deltas.
  """
  @spec request_reparse_buffer(EditorState.t(), pid()) :: EditorState.t()
  def request_reparse_buffer(%EditorState{} = state, buf_pid) when is_pid(buf_pid) do
    case ParserManager.begin_parse(buf_pid, state.parser_manager) do
      {:ok, buffer_id, version} ->
        content = Buffer.content(buf_pid)

        ParserManager.send_buffer_commands(
          buf_pid,
          buffer_id,
          [Protocol.encode_parse_buffer(buffer_id, version, content)],
          state.parser_manager
        )

        state

      :error ->
        opts = syntax_override_opts(state.highlighting, buf_pid)
        setup_for_buffer_pid(state, buf_pid, opts)
    end
  end

  @spec clear_active_document_symbols(EditorState.t()) :: EditorState.t()
  defp clear_active_document_symbols(
         %EditorState{workspace: %{buffers: %{active: active_buf}}} = state
       )
       when is_pid(active_buf) do
    EditorState.update_windows_for_buffer(state, active_buf, &Window.set_document_symbols(&1, []))
  end

  defp clear_active_document_symbols(%EditorState{} = state), do: state

  @spec send_parse_for_pid(EditorState.t(), pid(), String.t(), [setup_opt()]) :: EditorState.t()
  defp send_parse_for_pid(state, buf_pid, language, opts) do
    setup_fn = fn buffer_id -> setup_commands(buffer_id, buf_pid, language) end

    case register_parser_buffer(state, buf_pid, language, setup_fn) do
      :ok -> send_initial_parse(state, buf_pid, language, opts)
      :unavailable -> state
    end
  end

  @spec register_parser_buffer(EditorState.t(), pid(), String.t(), function()) ::
          :ok | :unavailable
  defp register_parser_buffer(state, buf_pid, language, setup_fn) do
    ParserManager.register_buffer(buf_pid, language, fn -> Buffer.content(buf_pid) end,
      setup_commands_fn: setup_fn,
      server: state.parser_manager
    )

    :ok
  catch
    :exit, reason ->
      Minga.Log.warning(:port, "Parser registration unavailable: #{inspect(reason)}")
      :unavailable
  end

  @spec send_initial_parse(EditorState.t(), pid(), String.t(), [setup_opt()]) :: EditorState.t()
  defp send_initial_parse(state, buf_pid, language, opts) do
    case ParserManager.begin_parse(buf_pid, state.parser_manager) do
      {:ok, buffer_id, version} ->
        commands = setup_commands(buffer_id, buf_pid, language, version)

        ParserManager.send_buffer_commands(
          buf_pid,
          buffer_id,
          commands,
          state.parser_manager
        )

        put_buffer_presentation(state, buf_pid, Keyword.get(opts, :syntax))

      :error ->
        state
    end
  end

  @spec setup_commands(pos_integer(), pid(), String.t(), non_neg_integer()) :: [binary()]
  defp setup_commands(buffer_id, buf_pid, language, version \\ 0) do
    Enum.concat([
      [Protocol.encode_set_language(buffer_id, language)],
      user_query_override(buffer_id, language),
      user_injection_query_override(buffer_id, language),
      user_fold_query_override(buffer_id, language),
      user_textobject_query_override(buffer_id, language),
      user_tags_query_override(buffer_id, language),
      [Protocol.encode_parse_buffer(buffer_id, version, Buffer.content(buf_pid))]
    ])
  end

  @spec put_buffer_presentation(EditorState.t(), pid(), MingaEditor.UI.Theme.syntax() | nil) ::
          EditorState.t()
  defp put_buffer_presentation(state, buf_pid, custom_syntax) do
    highlight =
      case custom_syntax do
        nil -> Highlight.from_theme(state.theme)
        syntax -> Highlight.new(syntax)
      end

    state = put_highlight(state, buf_pid, highlight)

    case custom_syntax do
      nil ->
        state

      syntax ->
        EditorState.update_highlight(state, fn presentation ->
          overrides = Map.put(presentation.syntax_overrides, buf_pid, syntax)
          Highlighting.set_syntax_overrides(presentation, overrides)
        end)
    end
  end

  @spec syntax_override_opts(Highlighting.t(), pid()) :: [setup_opt()]
  defp syntax_override_opts(%Highlighting{syntax_overrides: overrides}, buf_pid) do
    case Map.fetch(overrides, buf_pid) do
      {:ok, syntax} -> [syntax: syntax]
      :error -> []
    end
  end

  @spec send_parse_only(EditorState.t(), String.t()) :: EditorState.t()
  defp send_parse_only(state, language) do
    send_parse_for_pid(state, state.workspace.buffers.active, language, [])
  end

  @doc "Returns the registered parser buffer ID for the active buffer without allocating one."
  @spec ensure_buffer_id(EditorState.t()) :: {non_neg_integer(), EditorState.t()}
  def ensure_buffer_id(%EditorState{workspace: %{buffers: %{active: nil}}} = state),
    do: {0, state}

  def ensure_buffer_id(%EditorState{workspace: %{buffers: %{active: buf}}} = state) do
    {ParserManager.buffer_id(buf, state.parser_manager) || 0, state}
  end

  @doc """
  Sends a close_buffer command to the parser for a buffer that's being closed.
  Removes the buffer ID mapping.
  """
  @spec close_buffer(EditorState.t(), pid()) :: EditorState.t()
  def close_buffer(%EditorState{} = state, buffer_pid) do
    :ok = ParserManager.unregister_buffer(buffer_pid, state.parser_manager)

    EditorState.drop_parser_presentation(state, buffer_pid)
  end

  # Returns a list with a set_highlight_query command if the user has a custom
  # query file for this language, or an empty list to use the Zig built-in.
  @spec user_query_override(non_neg_integer(), String.t()) :: [binary()]
  defp user_query_override(buffer_id, language) do
    user_path = user_query_path(language)

    if user_path != nil and File.exists?(user_path) do
      case File.read(user_path) do
        {:ok, query_text} -> [Protocol.encode_set_highlight_query(buffer_id, query_text)]
        {:error, _} -> []
      end
    else
      []
    end
  end

  # Returns a list with a set_injection_query command if the user has a custom
  # injection query file for this language, or an empty list to use the Zig built-in.
  @spec user_injection_query_override(non_neg_integer(), String.t()) :: [binary()]
  defp user_injection_query_override(buffer_id, language) do
    user_path = user_injection_query_path(language)

    if user_path != nil and File.exists?(user_path) do
      case File.read(user_path) do
        {:ok, query_text} -> [Protocol.encode_set_injection_query(buffer_id, query_text)]
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
  @spec user_fold_query_override(non_neg_integer(), String.t()) :: [binary()]
  defp user_fold_query_override(buffer_id, language) do
    user_path = user_fold_query_path(language)

    if user_path != nil and File.exists?(user_path) do
      case File.read(user_path) do
        {:ok, query_text} -> [Protocol.encode_set_fold_query(buffer_id, query_text)]
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
  @spec user_textobject_query_override(non_neg_integer(), String.t()) :: [binary()]
  defp user_textobject_query_override(buffer_id, language) do
    user_path = user_textobject_query_path(language)

    if user_path != nil and File.exists?(user_path) do
      case File.read(user_path) do
        {:ok, query_text} -> [Protocol.encode_set_textobject_query(buffer_id, query_text)]
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

  # Returns a list with a set_tags_query command if the user has a custom
  # tags query file for this language, or an empty list to use the Zig built-in.
  @spec user_tags_query_override(non_neg_integer(), String.t()) :: [binary()]
  defp user_tags_query_override(buffer_id, language) do
    user_path = user_tags_query_path(language)

    if user_path != nil and File.exists?(user_path) do
      case File.read(user_path) do
        {:ok, query_text} -> [Protocol.encode_set_tags_query(buffer_id, query_text)]
        {:error, _} -> []
      end
    else
      []
    end
  end

  @spec user_tags_query_path(String.t()) :: String.t() | nil
  defp user_tags_query_path(language) do
    case System.user_home() do
      nil -> nil
      home -> Path.join([home, ".config", "minga", "queries", language, "tags.scm"])
    end
  end

  @doc """
  Sends a parse_buffer command for the current buffer content.

  Call this after content changes (insert, delete, paste, etc.).
  """
  @spec request_reparse(EditorState.t()) :: EditorState.t()
  def request_reparse(%EditorState{workspace: %{buffers: %{active: nil}}} = state), do: state

  def request_reparse(%EditorState{} = state) when state.workspace.buffers.active != nil do
    do_request_reparse(state)
  end

  defp do_request_reparse(%EditorState{} = state) do
    active = state.workspace.buffers.active

    case ParserManager.begin_parse(active, state.parser_manager) do
      {:ok, buffer_id, version} ->
        commands = parse_update_commands(active, buffer_id, version)

        ParserManager.send_buffer_commands(
          active,
          buffer_id,
          commands,
          state.parser_manager
        )

        state

      :error ->
        setup_for_buffer(state)
    end
  end

  @spec parse_update_commands(pid(), pos_integer(), pos_integer()) :: [binary()]
  defp parse_update_commands(buffer_pid, buffer_id, version) do
    case Buffer.consume_edit_deltas(buffer_pid, :highlight) do
      {:ok, []} ->
        [Protocol.encode_parse_buffer(buffer_id, version, Buffer.content(buffer_pid))]

      {:ok, edits} ->
        [Protocol.encode_edit_buffer(buffer_id, version, Enum.map(edits, &Map.from_struct/1))]

      :reset_required ->
        [Protocol.encode_parse_buffer(buffer_id, version, Buffer.content(buffer_pid))]
    end
  end

  # ── LRU eviction ──────────────────────────────────────────────────────────────

  # How often the eviction sweep runs (60 seconds).
  @eviction_check_interval_ms 60_000

  @doc """
  Returns the eviction check interval in milliseconds.
  Used by the Editor to schedule periodic `Process.send_after`.
  """
  @spec eviction_check_interval_ms() :: non_neg_integer()
  def eviction_check_interval_ms, do: @eviction_check_interval_ms

  @doc """
  Touches the last_active_at timestamp for the active buffer.
  Call on every parse, edit, or buffer focus.
  """
  @spec touch_active(EditorState.t()) :: EditorState.t()
  def touch_active(%EditorState{workspace: %{buffers: %{active: nil}}} = state), do: state

  def touch_active(%EditorState{} = state) do
    ParserManager.touch_buffer(state.workspace.buffers.active, state.parser_manager)
    state
  end

  @doc """
  Evicts inactive buffer trees from the Zig parser.

  Buffers whose last_active_at exceeds the TTL are evicted by sending
  close_buffer to the parser (frees tree + source on the Zig side).
  The buffer_id mapping is removed; on next access, `ensure_buffer_id`
  assigns a fresh ID and `setup_for_buffer` sends set_language + parse_buffer.

  The active buffer and any PIDs in `protected_pids` are never evicted.
  """
  @typedoc "Options for `evict_inactive/2`."
  @type evict_opt :: {:protected_pids, [pid()]} | {:ttl_ms, non_neg_integer()}

  @spec evict_inactive(EditorState.t(), [evict_opt()]) :: EditorState.t()
  def evict_inactive(%EditorState{} = state, opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_ms, 300_000)
    protected_pids = Keyword.get(opts, :protected_pids, [])
    active = state.workspace.buffers.active
    protected = [active | protected_pids] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case ParserManager.evict_inactive(protected, ttl_ms, state.parser_manager) do
      {:ok, []} ->
        state

      {:ok, pids} ->
        Minga.Log.debug(
          :editor,
          "Parser LRU: evicted #{Enum.count(pids)} inactive buffer tree(s)"
        )

        Enum.reduce(pids, state, &remove_evicted_presentation(&2, &1))

      {:error, :unavailable} ->
        state
    end
  end

  @spec remove_evicted_presentation(EditorState.t(), pid()) :: EditorState.t()
  defp remove_evicted_presentation(state, buffer_pid) do
    EditorState.drop_parser_presentation(state, buffer_pid)
  end

  @doc """
  Resolves a parser buffer_id to the buffer PID that owns it.
  Returns nil if the buffer_id is unknown (e.g., the buffer was closed).
  """
  @spec resolve_buffer_pid(EditorState.t(), non_neg_integer()) :: pid() | nil
  def resolve_buffer_pid(%EditorState{} = state, buffer_id) do
    ParserManager.resolve_buffer(buffer_id, state.parser_manager)
  end

  @doc "Handles a highlight_names event for the active buffer."
  @spec handle_names(EditorState.t(), [String.t()]) :: EditorState.t()
  def handle_names(%EditorState{} = state, names) do
    update_active_highlight(state, &Highlight.put_names(&1, names))
  end

  @doc "Handles a highlight_spans event for the active buffer."
  @spec handle_spans(EditorState.t(), non_neg_integer(), [
          MingaEditor.Frontend.Protocol.highlight_span()
        ]) ::
          EditorState.t()
  def handle_spans(%EditorState{} = state, version, spans) do
    update_active_highlight(state, &Highlight.put_spans(&1, version, spans))
  end

  # ── Per-buffer highlight helpers ─────────────────────────────────────────────

  @doc "Returns the parser buffer_id for a given buffer PID (read-only, no allocation)."
  @spec buffer_id_for(EditorState.t(), pid()) :: non_neg_integer()
  def buffer_id_for(%EditorState{} = state, buf_pid) do
    ParserManager.buffer_id(buf_pid, state.parser_manager) || 0
  end

  @doc "Returns the highlight data for the active buffer."
  @spec get_active_highlight(EditorState.t()) :: Highlight.t()
  def get_active_highlight(%EditorState{workspace: %{buffers: %{active: nil}}}),
    do: Highlight.new()

  def get_active_highlight(%EditorState{
        highlighting: highlighting,
        workspace: %{buffers: %{active: buf}}
      }) do
    Map.get(highlighting.highlights, buf, Highlight.new())
  end

  @doc "Returns the highlight data for a specific buffer PID."
  @spec get_highlight(EditorState.t(), pid()) :: Highlight.t()
  def get_highlight(%EditorState{highlighting: highlighting}, buf_pid) do
    Map.get(highlighting.highlights, buf_pid, Highlight.new())
  end

  @doc "Stores highlight data for the active buffer."
  @spec put_active_highlight(EditorState.t(), Highlight.t()) :: EditorState.t()
  def put_active_highlight(%EditorState{workspace: %{buffers: %{active: nil}}} = state, _hl_data),
    do: state

  def put_active_highlight(
        %EditorState{workspace: %{buffers: %{active: buf}}} = state,
        hl_data
      ) do
    EditorState.update_highlight(state, &Highlighting.put_highlight(&1, buf, hl_data))
  end

  @doc "Stores highlight data for a specific buffer PID."
  @spec put_highlight(EditorState.t(), pid(), Highlight.t()) :: EditorState.t()
  def put_highlight(%EditorState{} = state, buf_pid, hl_data) do
    EditorState.update_highlight(state, &Highlighting.put_highlight(&1, buf_pid, hl_data))
  end

  # Updates the active buffer's highlight via a function.
  @spec update_active_highlight(EditorState.t(), (Highlight.t() -> Highlight.t())) ::
          EditorState.t()
  defp update_active_highlight(%EditorState{workspace: %{buffers: %{active: nil}}} = state, _fun),
    do: state

  defp update_active_highlight(%EditorState{} = state, fun) do
    current = get_active_highlight(state)
    put_active_highlight(state, fun.(current))
  end
end
