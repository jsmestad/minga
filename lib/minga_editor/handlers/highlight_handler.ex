defmodule MingaEditor.Handlers.HighlightHandler do
  @moduledoc """
  Pure handler for highlight/parser events.

  Extracts the 15 `handle_info` clauses for `{:minga_highlight, _}` and
  `{:minga_input, _}` parser messages from the Editor GenServer into
  pure `{state, [effect]}` functions. The Editor delegates to this module
  via 1-2 catch-all clauses and applies the returned effects.

  Each function reads and writes only highlight-related state slices
  (`state.highlighting`, `state.injection_ranges`,
  `state.parser_status`). Cross-cutting concerns (render, log, timer
  scheduling) are expressed as effects.
  """

  alias Minga.Parser.EventCorrelation
  alias MingaEditor.HighlightEvents
  alias MingaEditor.HighlightSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.Window
  alias Minga.Editing.Fold.Range, as: FoldRange

  @typedoc "Effects that the highlight handler may return."
  @type highlight_effect ::
          :render
          | {:render, pos_integer()}
          | {:log_message, String.t()}
          | {:log, atom(), atom(), String.t()}
          | {:setup_highlight_sync, pid()}
          | {:request_semantic_tokens}
          | {:send_after, term(), non_neg_integer()}
          | {:conceal_spans, pid(), [map()]}
          | {:prettify_symbols, pid()}
          | {:update_agent_styled_cache}
          | {:evict_parser_trees_timer}

  @doc """
  Dispatches a highlight/parser message to the appropriate handler.

  Returns `{state, effects}` where effects encode all side-effectful
  operations (render, log, timer scheduling, etc.).
  """
  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [highlight_effect()]}

  # ── :setup_highlight ──────────────────────────────────────────────────────

  def handle(state, :setup_highlight) do
    new_state = HighlightSync.setup_for_buffer(state)
    {new_state, [{:request_semantic_tokens}]}
  end

  # ── correlated buffer events ─────────────────────────────────────────────

  def handle(
        state,
        {:minga_highlight,
         {:buffer_event, buffer_pid, %EventCorrelation{} = correlation, payload}}
      )
      when is_pid(buffer_pid) do
    highlight = HighlightSync.get_highlight(state, buffer_pid)

    if MingaEditor.UI.Highlight.accepts_correlation?(highlight, correlation) do
      {state, effects} = handle(state, {:minga_highlight, attach_buffer(payload, buffer_pid)})

      updated =
        state
        |> HighlightSync.get_highlight(buffer_pid)
        |> MingaEditor.UI.Highlight.accept_correlation(correlation)

      {HighlightSync.put_highlight(state, buffer_pid, updated), effects}
    else
      {state, []}
    end
  end

  # ── highlight_names ──────────────────────────────────────────────────────

  def handle(state, {:minga_highlight, {:highlight_names, buffer_pid, names}})
      when is_pid(buffer_pid) do
    handle_highlight_names(state, buffer_pid, names)
  end

  # ── injection_ranges ─────────────────────────────────────────────────────

  def handle(state, {:minga_highlight, {:injection_ranges, buffer_pid, ranges}})
      when is_pid(buffer_pid) do
    handle_injection_ranges(state, buffer_pid, ranges)
  end

  # ── language_at_response (no-op) ─────────────────────────────────────────

  def handle(state, {tag, {:language_at_response, _request_id, _language}})
      when tag in [:minga_highlight, :minga_input] do
    {state, []}
  end

  # ── highlight_spans ──────────────────────────────────────────────────────

  def handle(state, {:minga_highlight, {:highlight_spans, buffer_pid, spans}})
      when is_pid(buffer_pid) do
    presentation_version = HighlightSync.get_highlight(state, buffer_pid).version + 1
    handle_highlight_spans(state, buffer_pid, presentation_version, spans)
  end

  # ── conceal_spans ────────────────────────────────────────────────────────

  def handle(state, {:minga_highlight, {:conceal_spans, buffer_pid, spans}})
      when is_pid(buffer_pid) do
    handle_conceal_spans(state, buffer_pid, spans)
  end

  # ── fold_ranges ──────────────────────────────────────────────────────────

  def handle(state, {:minga_highlight, {:fold_ranges, buffer_pid, ranges}})
      when is_pid(buffer_pid) do
    handle_fold_ranges(state, buffer_pid, ranges)
  end

  # ── textobject_positions ─────────────────────────────────────────────────

  def handle(state, {:minga_highlight, {:textobject_positions, buffer_pid, positions}})
      when is_pid(buffer_pid) do
    handle_textobject_positions(state, buffer_pid, positions)
  end

  # ── document_symbols ─────────────────────────────────────────────────────

  def handle(state, {:minga_highlight, {:document_symbols, buffer_pid, symbols}})
      when is_pid(buffer_pid) do
    handle_document_symbols(state, buffer_pid, symbols)
  end

  # ── grammar_loaded ───────────────────────────────────────────────────────

  def handle(state, {tag, {:grammar_loaded, true, name}})
      when tag in [:minga_highlight, :minga_input] do
    {state, [{:log, :editor, :info, "Grammar loaded: #{name}"}]}
  end

  def handle(state, {tag, {:grammar_loaded, false, name}})
      when tag in [:minga_highlight, :minga_input] do
    {state, [{:log, :editor, :warning, "Grammar failed to load: #{name}"}]}
  end

  # ── log_message (from renderer port) ─────────────────────────────────────

  def handle(state, {:minga_input, {:log_message, level, text}}) do
    prefix = MingaEditor.MessageLog.frontend_prefix(state)
    {state, [{:log_message, "[#{prefix}/#{level}] #{text}"}]}
  end

  # ── log_message (from parser port) ───────────────────────────────────────

  def handle(state, {:minga_highlight, {:log_message, level, text}}) do
    {state, [{:log_message, "[PARSER/#{level}] #{text}"}]}
  end

  # ── parser_crashed ───────────────────────────────────────────────────────

  def handle(state, {:minga_highlight, :parser_crashed}) do
    {%{state | parser_status: :restarting}, []}
  end

  # ── parser_restarted ─────────────────────────────────────────────────────

  def handle(state, {:minga_highlight, :parser_restarted}) do
    handle_parser_restarted(state)
  end

  # ── parser_gave_up ───────────────────────────────────────────────────────

  def handle(state, {:minga_highlight, :parser_gave_up}) do
    new_state = %{state | parser_status: :unavailable}

    {new_state,
     [
       {:log_message,
        "Parser crashed repeatedly, syntax highlighting disabled. Use :parser-restart to retry."}
     ]}
  end

  # ── evict_parser_trees ───────────────────────────────────────────────────

  def handle(state, :evict_parser_trees) do
    handle_evict_parser_trees(state)
  end

  # ── Catch-all for unrecognized highlight messages ────────────────────────

  def handle(state, _msg) do
    {state, []}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec attach_buffer(term(), pid()) :: term()
  defp attach_buffer({:highlight_names, names}, pid), do: {:highlight_names, pid, names}
  defp attach_buffer({:highlight_spans, spans}, pid), do: {:highlight_spans, pid, spans}
  defp attach_buffer({:injection_ranges, ranges}, pid), do: {:injection_ranges, pid, ranges}
  defp attach_buffer({:conceal_spans, spans}, pid), do: {:conceal_spans, pid, spans}
  defp attach_buffer({:fold_ranges, ranges}, pid), do: {:fold_ranges, pid, ranges}

  defp attach_buffer({:textobject_positions, positions}, pid),
    do: {:textobject_positions, pid, positions}

  defp attach_buffer({:document_symbols, symbols}, pid), do: {:document_symbols, pid, symbols}
  defp attach_buffer(payload, _pid), do: payload

  @spec handle_highlight_names(EditorState.t(), pid(), [String.t()]) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_highlight_names(%{highlighting: %{highlights: highlights}} = state, pid, _names)
       when not is_map_key(highlights, pid),
       do: {state, []}

  defp handle_highlight_names(state, pid, names) when pid == state.workspace.buffers.active do
    new_state = HighlightEvents.handle_names(state, names)
    {new_state, []}
  end

  defp handle_highlight_names(state, pid, names) do
    existing = HighlightSync.get_highlight(state, pid)
    updated = MingaEditor.UI.Highlight.put_names(existing, names)
    new_state = HighlightSync.put_highlight(state, pid, updated)
    {new_state, []}
  end

  @spec handle_injection_ranges(EditorState.t(), pid(), term()) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_injection_ranges(%{highlighting: %{highlights: highlights}} = state, pid, _ranges)
       when not is_map_key(highlights, pid),
       do: {state, []}

  defp handle_injection_ranges(state, pid, ranges) do
    new_state = EditorState.update_injection_ranges(state, &Map.put(&1, pid, ranges))
    {new_state, []}
  end

  @spec handle_highlight_spans(EditorState.t(), pid(), non_neg_integer(), term()) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_highlight_spans(
         %{highlighting: %{highlights: highlights}} = state,
         pid,
         _version,
         _spans
       )
       when not is_map_key(highlights, pid),
       do: {state, []}

  defp handle_highlight_spans(state, pid, version, spans)
       when pid == state.workspace.buffers.active do
    new_state = HighlightSync.handle_spans(state, version, spans)
    {new_state, [{:prettify_symbols, pid}, :render]}
  end

  defp handle_highlight_spans(state, pid, version, spans) do
    existing = HighlightSync.get_highlight(state, pid)
    updated = MingaEditor.UI.Highlight.put_spans(existing, version, spans)
    state_with_hl = HighlightSync.put_highlight(state, pid, updated)

    effects = if buffer_visible_in_window?(state_with_hl, pid), do: [:render], else: []
    {state_with_hl, effects}
  end

  @spec handle_conceal_spans(EditorState.t(), pid(), [map()]) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_conceal_spans(%{highlighting: %{highlights: highlights}} = state, pid, _spans)
       when not is_map_key(highlights, pid),
       do: {state, []}

  defp handle_conceal_spans(state, pid, spans), do: {state, [{:conceal_spans, pid, spans}]}

  @spec handle_fold_ranges(EditorState.t(), pid(), [
          {non_neg_integer(), non_neg_integer()}
        ]) :: {EditorState.t(), [highlight_effect()]}
  defp handle_fold_ranges(state, pid, ranges) when pid == state.workspace.buffers.active do
    fold_ranges =
      Enum.map(ranges, fn {start_line, end_line} ->
        FoldRange.new!(start_line, end_line)
      end)

    new_state =
      case EditorState.active_window_struct(state) do
        nil ->
          state

        %Window{id: id} ->
          EditorState.update_window(state, id, &Window.set_fold_ranges(&1, fold_ranges))
      end

    effects = [
      {:log, :editor, :debug,
       "Fold ranges received: buffer=#{inspect(pid)}, count=#{Enum.count(ranges)}"}
    ]

    {new_state, effects}
  end

  defp handle_fold_ranges(state, _pid, _ranges), do: {state, []}

  @spec handle_textobject_positions(EditorState.t(), pid(), map()) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_textobject_positions(state, pid, positions)
       when pid == state.workspace.buffers.active do
    new_state =
      case EditorState.active_window_struct(state) do
        nil ->
          state

        %Window{id: id} ->
          EditorState.update_window(state, id, &%{&1 | textobject_positions: positions})
      end

    {new_state, []}
  end

  defp handle_textobject_positions(state, _pid, _positions), do: {state, []}

  @spec handle_document_symbols(EditorState.t(), pid(), [Minga.Language.Symbol.t()]) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_document_symbols(state, pid, symbols) do
    new_state =
      EditorState.update_windows_for_buffer(state, pid, &Window.set_document_symbols(&1, symbols))

    {new_state, []}
  end

  @spec handle_parser_restarted(EditorState.t()) :: {EditorState.t(), [highlight_effect()]}
  defp handle_parser_restarted(state) do
    reset_highlights =
      Map.new(state.highlighting.highlights, fn {pid, buffer_highlight} ->
        reset =
          buffer_highlight
          |> Map.put(:version, 0)
          |> MingaEditor.UI.Highlight.reset_parser_version()

        {pid, reset}
      end)

    new_state =
      state
      |> EditorState.update_highlight(&Highlighting.set_highlights(&1, reset_highlights))
      |> Map.put(:parser_status, :available)
      |> EditorState.reset_frontend_render_state()

    {new_state, [{:log_message, "Parser restarted, syntax highlighting recovered"}]}
  end

  @spec handle_evict_parser_trees(EditorState.t()) :: {EditorState.t(), [highlight_effect()]}
  defp handle_evict_parser_trees(state) do
    ttl_seconds = Minga.Config.get(:parser_tree_ttl)

    new_state =
      HighlightSync.evict_inactive(state,
        ttl_ms: ttl_seconds * 1_000,
        protected_pids: parser_eviction_protected_pids(state)
      )

    effects =
      if state.backend != :headless do
        [{:evict_parser_trees_timer}]
      else
        []
      end

    {new_state, effects}
  end

  @spec parser_eviction_protected_pids(EditorState.t()) :: [pid()]
  defp parser_eviction_protected_pids(state) do
    state
    |> visible_window_buffers()
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  @spec visible_window_buffers(EditorState.t()) :: [pid()]
  defp visible_window_buffers(state) do
    state.workspace.windows.map
    |> Map.values()
    |> Enum.map(& &1.buffer)
    |> Enum.filter(&is_pid/1)
  end

  # Returns true if the given buffer PID is visible in any window.
  @spec buffer_visible_in_window?(EditorState.t(), pid()) :: boolean()
  defp buffer_visible_in_window?(state, buf_pid) do
    Enum.any?(state.workspace.windows.map, fn {_id, win} -> win.buffer == buf_pid end)
  end
end
