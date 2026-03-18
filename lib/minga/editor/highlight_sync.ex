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
        put_active_highlight(state, Highlight.from_theme(state.theme))
    end
  end

  @typedoc "Options for `setup_for_buffer_pid/3`."
  @type setup_opt :: {:syntax, Minga.Theme.syntax()}

  @doc """
  Sets up highlighting for a specific buffer PID that may not be the active buffer.

  Used for persistent buffers like `*Agent*` that live in side panels and need
  tree-sitter parsing even when they're not the focused buffer. Assigns a
  buffer_id, sends set_language + parse_buffer to the parser, and initializes
  the highlight entry.

  ## Options

    * `:syntax` — custom syntax theme map to use instead of the global theme's
      syntax. Used by the agent buffer to override delimiter captures with
      dimmed colors.
  """
  @spec setup_for_buffer_pid(EditorState.t(), pid(), [setup_opt()]) :: EditorState.t()
  def setup_for_buffer_pid(state, buf_pid, opts \\ [])

  def setup_for_buffer_pid(%EditorState{} = state, buf_pid, opts) when is_pid(buf_pid) do
    filetype = BufferServer.filetype(buf_pid)

    case Grammar.language_for_filetype(filetype) do
      {:ok, language} ->
        send_parse_for_pid(state, buf_pid, language, opts)

      :unsupported ->
        state
    end
  end

  @doc """
  Requests a full reparse of a specific buffer PID.

  Used after content changes to non-active buffers (e.g., agent buffer sync).
  Sends a parse_buffer command with the full content since replace_content_force
  clears pending edit deltas.
  """
  @spec request_reparse_buffer(EditorState.t(), pid()) :: EditorState.t()
  def request_reparse_buffer(%EditorState{} = state, buf_pid) when is_pid(buf_pid) do
    hl = state.highlight

    case Map.fetch(hl.buffer_ids, buf_pid) do
      {:ok, buffer_id} ->
        version = hl.version + 1
        content = BufferServer.content(buf_pid)
        parse_cmd = Protocol.encode_parse_buffer(buffer_id, version, content)
        ParserManager.send_commands([parse_cmd])

        state = %{state | highlight: %{hl | version: version}}
        touch_buffer(state, buf_pid)

      :error ->
        # Buffer not registered with parser yet; set up from scratch.
        # Recover any stored syntax override (e.g., agent buffer's dimmed delimiters).
        opts =
          case Map.get(hl.syntax_overrides, buf_pid) do
            nil -> []
            syntax -> [syntax: syntax]
          end

        setup_for_buffer_pid(state, buf_pid, opts)
    end
  end

  @spec send_parse_for_pid(EditorState.t(), pid(), String.t(), [setup_opt()]) :: EditorState.t()
  defp send_parse_for_pid(state, buf_pid, language, opts) do
    {buffer_id, state} = ensure_buffer_id_for(state, buf_pid)
    hl = state.highlight
    version = hl.version + 1
    content = BufferServer.content(buf_pid)

    query_override = user_query_override(buffer_id, language)
    injection_override = user_injection_query_override(buffer_id, language)
    fold_override = user_fold_query_override(buffer_id, language)
    textobject_override = user_textobject_query_override(buffer_id, language)

    parse_cmd = Protocol.encode_parse_buffer(buffer_id, version, content)

    commands =
      Enum.concat([
        [Protocol.encode_set_language(buffer_id, language)],
        query_override,
        injection_override,
        fold_override,
        textobject_override,
        [parse_cmd]
      ])

    ParserManager.send_commands(commands)

    # Register this buffer for crash recovery re-sync. The setup_commands_fn
    # replays the full command set (including custom queries) so user overrides
    # survive a parser crash.
    setup_fn = fn bid ->
      fresh_content = BufferServer.content(buf_pid)

      Enum.concat([
        [Protocol.encode_set_language(bid, language)],
        user_query_override(bid, language),
        user_injection_query_override(bid, language),
        user_fold_query_override(bid, language),
        user_textobject_query_override(bid, language),
        [Protocol.encode_parse_buffer(bid, 0, fresh_content)]
      ])
    end

    ParserManager.register_buffer(
      buffer_id,
      language,
      fn -> BufferServer.content(buf_pid) end,
      setup_commands_fn: setup_fn
    )

    # Use custom syntax theme if provided (e.g., agent buffer with dimmed delimiters),
    # otherwise use the global editor theme. Store the override so
    # request_reparse_buffer can recover it if the buffer_id is lost.
    custom_syntax = Keyword.get(opts, :syntax)

    hl_data =
      case custom_syntax do
        nil -> Highlight.from_theme(state.theme)
        syntax -> Highlight.new(syntax)
      end

    state = put_highlight(state, buf_pid, hl_data)

    hl2 = state.highlight

    syntax_overrides =
      if custom_syntax do
        Map.put(hl2.syntax_overrides, buf_pid, custom_syntax)
      else
        hl2.syntax_overrides
      end

    state = %{state | highlight: %{hl2 | version: version, syntax_overrides: syntax_overrides}}
    touch_buffer(state, buf_pid)
  end

  # Returns the parser buffer_id for a given buffer PID, assigning one if needed.
  # Private: callers should use setup_for_buffer_pid/2 or request_reparse_buffer/2
  # which handle the full language + parse protocol.
  @spec ensure_buffer_id_for(EditorState.t(), pid()) :: {non_neg_integer(), EditorState.t()}
  defp ensure_buffer_id_for(%EditorState{highlight: hl} = state, buf_pid) do
    case Map.fetch(hl.buffer_ids, buf_pid) do
      {:ok, id} ->
        {id, state}

      :error ->
        assign_new_buffer_id(state, hl, buf_pid)
    end
  end

  # Touches the last_active_at timestamp for a specific buffer PID.
  @spec touch_buffer(EditorState.t(), pid()) :: EditorState.t()
  defp touch_buffer(%EditorState{} = state, buf_pid) do
    hl = state.highlight
    now = System.monotonic_time(:millisecond)
    timestamps = Map.put(hl.last_active_at, buf_pid, now)
    %{state | highlight: %{hl | last_active_at: timestamps}}
  end

  @spec send_parse_only(EditorState.t(), String.t()) :: EditorState.t()
  defp send_parse_only(state, language) do
    {buffer_id, state} = ensure_buffer_id(state)
    hl = state.highlight
    version = hl.version + 1
    content = BufferServer.content(state.buffers.active)

    query_override = user_query_override(buffer_id, language)
    injection_override = user_injection_query_override(buffer_id, language)
    fold_override = user_fold_query_override(buffer_id, language)
    textobject_override = user_textobject_query_override(buffer_id, language)

    parse_cmd = Protocol.encode_parse_buffer(buffer_id, version, content)

    commands =
      Enum.concat([
        [Protocol.encode_set_language(buffer_id, language)],
        query_override,
        injection_override,
        fold_override,
        textobject_override,
        [parse_cmd]
      ])

    ParserManager.send_commands(commands)

    # Register for crash recovery re-sync (including custom queries).
    active = state.buffers.active

    setup_fn = fn bid ->
      fresh_content = BufferServer.content(active)

      Enum.concat([
        [Protocol.encode_set_language(bid, language)],
        user_query_override(bid, language),
        user_injection_query_override(bid, language),
        user_fold_query_override(bid, language),
        user_textobject_query_override(bid, language),
        [Protocol.encode_parse_buffer(bid, 0, fresh_content)]
      ])
    end

    ParserManager.register_buffer(
      buffer_id,
      language,
      fn -> BufferServer.content(active) end,
      setup_commands_fn: setup_fn
    )

    state = put_active_highlight(state, Highlight.from_theme(state.theme))
    hl2 = state.highlight
    state = %{state | highlight: %{hl2 | version: version}}
    touch_active(state)
  end

  @doc """
  Returns the parser buffer_id for the active buffer, assigning one if needed.

  Returns `{buffer_id, updated_state}`. The buffer_id is a monotonically
  incrementing u32 stored in `highlight.buffer_ids`.
  """
  @spec ensure_buffer_id(EditorState.t()) :: {non_neg_integer(), EditorState.t()}
  def ensure_buffer_id(%EditorState{buffers: %{active: nil}} = state), do: {0, state}

  def ensure_buffer_id(%EditorState{highlight: hl, buffers: %{active: buf}} = state) do
    case Map.fetch(hl.buffer_ids, buf) do
      {:ok, id} ->
        {id, state}

      :error ->
        assign_new_buffer_id(state, hl, buf)
    end
  end

  @spec assign_new_buffer_id(EditorState.t(), Minga.Editor.State.Highlighting.t(), pid()) ::
          {non_neg_integer(), EditorState.t()}
  defp assign_new_buffer_id(state, hl, buf) do
    id = hl.next_buffer_id

    new_hl = %{
      hl
      | buffer_ids: Map.put(hl.buffer_ids, buf, id),
        reverse_buffer_ids: Map.put(hl.reverse_buffer_ids, id, buf),
        next_buffer_id: id + 1
    }

    {id, %{state | highlight: new_hl}}
  end

  @doc """
  Sends a close_buffer command to the parser for a buffer that's being closed.
  Removes the buffer ID mapping.
  """
  @spec close_buffer(EditorState.t(), pid()) :: EditorState.t()
  def close_buffer(%EditorState{} = state, buffer_pid) do
    hl = state.highlight

    case Map.pop(hl.buffer_ids, buffer_pid) do
      {nil, _ids} ->
        state

      {buffer_id, remaining_ids} ->
        ParserManager.close_buffer(buffer_id)
        ParserManager.unregister_buffer(buffer_id)

        %{
          state
          | highlight: %{
              hl
              | buffer_ids: remaining_ids,
                reverse_buffer_ids: Map.delete(hl.reverse_buffer_ids, buffer_id),
                highlights: Map.delete(hl.highlights, buffer_pid),
                last_active_at: Map.delete(hl.last_active_at, buffer_pid),
                syntax_overrides: Map.delete(hl.syntax_overrides, buffer_pid)
            }
        }
    end
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

  @doc """
  Sends a parse_buffer command for the current buffer content.

  Call this after content changes (insert, delete, paste, etc.).
  """
  @spec request_reparse(EditorState.t()) :: EditorState.t()
  def request_reparse(%EditorState{buffers: %{active: nil}} = state), do: state

  def request_reparse(%EditorState{} = state) when state.buffers.active != nil do
    active_hl = get_active_highlight(state)

    if active_hl.spans == {} and active_hl.capture_names == {} do
      # No highlighting active for this buffer — skip
      state
    else
      do_request_reparse(state)
    end
  end

  defp do_request_reparse(%EditorState{} = state) do
    {buffer_id, state} = ensure_buffer_id(state)
    hl = state.highlight
    version = hl.version + 1

    # Try incremental sync first: if the buffer has pending edit deltas,
    # send them as an edit_buffer command instead of the full content.
    edits = BufferServer.flush_edits(state.buffers.active)

    commands =
      if edits != [] do
        delta_maps = Enum.map(edits, &Map.from_struct/1)
        [Protocol.encode_edit_buffer(buffer_id, version, delta_maps)]
      else
        # No deltas (e.g., undo/redo, content replaced externally): full sync
        content = BufferServer.content(state.buffers.active)
        [Protocol.encode_parse_buffer(buffer_id, version, content)]
      end

    ParserManager.send_commands(commands)

    state = %{state | highlight: %{hl | version: version}}
    touch_active(state)
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
  def touch_active(%EditorState{buffers: %{active: nil}} = state), do: state

  def touch_active(%EditorState{} = state) do
    hl = state.highlight
    now = System.monotonic_time(:millisecond)
    timestamps = Map.put(hl.last_active_at, state.buffers.active, now)
    %{state | highlight: %{hl | last_active_at: timestamps}}
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
    hl = state.highlight
    now = System.monotonic_time(:millisecond)
    ttl_ms = Keyword.get(opts, :ttl_ms, 300_000)
    protected_pids = Keyword.get(opts, :protected_pids, [])

    active = state.buffers.active
    protected = MapSet.new([active | protected_pids] |> Enum.reject(&is_nil/1))

    {evicted_ids, remaining_timestamps} =
      find_stale_buffers(hl, now, ttl_ms, protected)

    apply_evictions(state, evicted_ids, remaining_timestamps)
  end

  @spec find_stale_buffers(
          Minga.Editor.State.Highlighting.t(),
          integer(),
          non_neg_integer(),
          MapSet.t()
        ) ::
          {[{pid(), non_neg_integer()}], %{pid() => integer()}}
  defp find_stale_buffers(hl, now, ttl, protected) do
    Enum.reduce(hl.last_active_at, {[], %{}}, fn {pid, last_ts}, {evicted, kept} ->
      stale? = now - last_ts > ttl
      guarded? = MapSet.member?(protected, pid)

      if stale? and not guarded? do
        classify_stale_buffer(hl, pid, evicted, kept)
      else
        {evicted, Map.put(kept, pid, last_ts)}
      end
    end)
  end

  @spec classify_stale_buffer(
          Minga.Editor.State.Highlighting.t(),
          pid(),
          [{pid(), non_neg_integer()}],
          %{pid() => integer()}
        ) :: {[{pid(), non_neg_integer()}], %{pid() => integer()}}
  defp classify_stale_buffer(hl, pid, evicted, kept) do
    case Map.get(hl.buffer_ids, pid) do
      nil -> {evicted, kept}
      id -> {[{pid, id} | evicted], kept}
    end
  end

  @spec apply_evictions(EditorState.t(), [{pid(), non_neg_integer()}], %{pid() => integer()}) ::
          EditorState.t()
  defp apply_evictions(state, [], _remaining_timestamps), do: state

  defp apply_evictions(state, evicted_ids, remaining_timestamps) do
    # Action: send close_buffer commands to the Zig parser.
    Enum.each(evicted_ids, fn {_pid, id} -> ParserManager.close_buffer(id) end)

    Minga.Log.debug(
      :editor,
      "Parser LRU: evicted #{length(evicted_ids)} inactive buffer tree(s)"
    )

    # Calculation: compute the new highlighting state with evicted entries removed.
    new_hl = compute_post_eviction_state(state.highlight, evicted_ids, remaining_timestamps)
    %{state | highlight: new_hl}
  end

  # Pure calculation: produces the new Highlighting struct with evicted entries removed.
  @spec compute_post_eviction_state(
          Minga.Editor.State.Highlighting.t(),
          [{pid(), non_neg_integer()}],
          %{pid() => integer()}
        ) :: Minga.Editor.State.Highlighting.t()
  defp compute_post_eviction_state(hl, evicted_ids, remaining_timestamps) do
    evicted_pids = MapSet.new(evicted_ids, fn {pid, _id} -> pid end)
    evicted_id_set = MapSet.new(evicted_ids, fn {_pid, id} -> id end)

    %{
      hl
      | buffer_ids:
          Map.reject(hl.buffer_ids, fn {pid, _} -> MapSet.member?(evicted_pids, pid) end),
        reverse_buffer_ids:
          Map.reject(hl.reverse_buffer_ids, fn {id, _} -> MapSet.member?(evicted_id_set, id) end),
        highlights:
          Map.reject(hl.highlights, fn {pid, _} -> MapSet.member?(evicted_pids, pid) end),
        last_active_at: remaining_timestamps
    }
  end

  @doc """
  Resolves a parser buffer_id to the buffer PID that owns it.
  Returns nil if the buffer_id is unknown (e.g., the buffer was closed).
  """
  @spec resolve_buffer_pid(EditorState.t(), non_neg_integer()) :: pid() | nil
  def resolve_buffer_pid(%EditorState{highlight: hl}, buffer_id) do
    Map.get(hl.reverse_buffer_ids, buffer_id)
  end

  @doc "Handles a highlight_names event for the active buffer."
  @spec handle_names(EditorState.t(), [String.t()]) :: EditorState.t()
  def handle_names(%EditorState{} = state, names) do
    update_active_highlight(state, &Highlight.put_names(&1, names))
  end

  @doc "Handles a highlight_spans event for the active buffer."
  @spec handle_spans(EditorState.t(), non_neg_integer(), [Minga.Port.Protocol.highlight_span()]) ::
          EditorState.t()
  def handle_spans(%EditorState{} = state, version, spans) do
    update_active_highlight(state, &Highlight.put_spans(&1, version, spans))
  end

  # ── Per-buffer highlight helpers ─────────────────────────────────────────────

  @doc "Returns the parser buffer_id for a given buffer PID (read-only, no allocation)."
  @spec buffer_id_for(EditorState.t(), pid()) :: non_neg_integer()
  def buffer_id_for(%EditorState{highlight: hl}, buf_pid) do
    Map.get(hl.buffer_ids, buf_pid, 0)
  end

  @doc "Returns the highlight data for the active buffer."
  @spec get_active_highlight(EditorState.t()) :: Highlight.t()
  def get_active_highlight(%EditorState{buffers: %{active: nil}}), do: Highlight.new()

  def get_active_highlight(%EditorState{highlight: hl, buffers: %{active: buf}}) do
    Map.get(hl.highlights, buf, Highlight.new())
  end

  @doc "Returns the highlight data for a specific buffer PID."
  @spec get_highlight(EditorState.t(), pid()) :: Highlight.t()
  def get_highlight(%EditorState{highlight: hl}, buf_pid) do
    Map.get(hl.highlights, buf_pid, Highlight.new())
  end

  @doc "Stores highlight data for the active buffer."
  @spec put_active_highlight(EditorState.t(), Highlight.t()) :: EditorState.t()
  def put_active_highlight(%EditorState{buffers: %{active: nil}} = state, _hl_data), do: state

  def put_active_highlight(%EditorState{highlight: hl, buffers: %{active: buf}} = state, hl_data) do
    %{state | highlight: %{hl | highlights: Map.put(hl.highlights, buf, hl_data)}}
  end

  @doc "Stores highlight data for a specific buffer PID."
  @spec put_highlight(EditorState.t(), pid(), Highlight.t()) :: EditorState.t()
  def put_highlight(%EditorState{highlight: hl} = state, buf_pid, hl_data) do
    %{state | highlight: %{hl | highlights: Map.put(hl.highlights, buf_pid, hl_data)}}
  end

  # Updates the active buffer's highlight via a function.
  @spec update_active_highlight(EditorState.t(), (Highlight.t() -> Highlight.t())) ::
          EditorState.t()
  defp update_active_highlight(%EditorState{buffers: %{active: nil}} = state, _fun), do: state

  defp update_active_highlight(%EditorState{} = state, fun) do
    current = get_active_highlight(state)
    put_active_highlight(state, fun.(current))
  end
end
