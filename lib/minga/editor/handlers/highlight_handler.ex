defmodule Minga.Editor.Handlers.HighlightHandler do
  @moduledoc """
  Pure handler for highlight/parser events.

  Extracts the 15 `handle_info` clauses for `{:minga_highlight, _}` and
  `{:minga_input, _}` parser messages from the Editor GenServer into
  pure `{state, [effect]}` functions. The Editor delegates to this module
  via 1-2 catch-all clauses and applies the returned effects.

  Each function reads and writes only highlight-related state slices
  (`state.workspace.highlight`, `state.workspace.injection_ranges`,
  `state.parser_status`). Cross-cutting concerns (render, log, timer
  scheduling) are expressed as effects.
  """

  alias Minga.Editor.HighlightEvents
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.Window
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

  # ── highlight_names ──────────────────────────────────────────────────────

  def handle(state, {tag, {:highlight_names, buffer_id, names}})
      when tag in [:minga_highlight, :minga_input] do
    pid = HighlightSync.resolve_buffer_pid(state, buffer_id)
    handle_highlight_names(state, pid, buffer_id, names)
  end

  # ── injection_ranges ─────────────────────────────────────────────────────

  def handle(state, {tag, {:injection_ranges, buffer_id, ranges}})
      when tag in [:minga_highlight, :minga_input] do
    pid = HighlightSync.resolve_buffer_pid(state, buffer_id)
    handle_injection_ranges(state, pid, buffer_id, ranges)
  end

  # ── language_at_response (no-op) ─────────────────────────────────────────

  def handle(state, {tag, {:language_at_response, _request_id, _language}})
      when tag in [:minga_highlight, :minga_input] do
    {state, []}
  end

  # ── highlight_spans ──────────────────────────────────────────────────────

  def handle(state, {tag, {:highlight_spans, buffer_id, version, spans}})
      when tag in [:minga_highlight, :minga_input] do
    pid = HighlightSync.resolve_buffer_pid(state, buffer_id)
    handle_highlight_spans(state, pid, buffer_id, version, spans)
  end

  # ── conceal_spans ────────────────────────────────────────────────────────

  def handle(state, {tag, {:conceal_spans, buffer_id, _version, spans}})
      when tag in [:minga_highlight, :minga_input] do
    pid = HighlightSync.resolve_buffer_pid(state, buffer_id)
    handle_conceal_spans(state, pid, buffer_id, spans)
  end

  # ── fold_ranges ──────────────────────────────────────────────────────────

  def handle(state, {tag, {:fold_ranges, buffer_id, _version, ranges}})
      when tag in [:minga_highlight, :minga_input] do
    pid = HighlightSync.resolve_buffer_pid(state, buffer_id)
    handle_fold_ranges(state, pid, buffer_id, ranges)
  end

  # ── textobject_positions ─────────────────────────────────────────────────

  def handle(state, {tag, {:textobject_positions, buffer_id, _version, positions}})
      when tag in [:minga_highlight, :minga_input] do
    pid = HighlightSync.resolve_buffer_pid(state, buffer_id)
    handle_textobject_positions(state, pid, buffer_id, positions)
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
    prefix = Minga.Editor.MessageLog.frontend_prefix(state)
    {state, [{:log_message, "[#{prefix}/#{level}] #{text}"}]}
  end

  # ── log_message (from parser port) ───────────────────────────────────────

  def handle(state, {:minga_highlight, {:log_message, level, text}}) do
    {state, [{:log_message, "[PARSER/#{level}] #{text}"}]}
  end

  # ── request_reparse ──────────────────────────────────────────────────────

  def handle(state, {:minga_highlight, {:request_reparse, buffer_id}}) do
    handle_request_reparse(state, buffer_id)
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

  @spec handle_highlight_names(EditorState.t(), pid() | nil, non_neg_integer(), [String.t()]) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_highlight_names(state, nil, buffer_id, _names) do
    {state,
     [{:log, :editor, :warning, "highlight_names for unknown buffer_id=#{buffer_id}, discarding"}]}
  end

  defp handle_highlight_names(state, pid, _buffer_id, names)
       when pid == state.workspace.buffers.active do
    new_state = HighlightEvents.handle_names(state, names)
    {new_state, []}
  end

  defp handle_highlight_names(state, pid, _buffer_id, names) do
    existing = HighlightSync.get_highlight(state, pid)
    updated = Minga.UI.Highlight.put_names(existing, names)
    new_state = HighlightSync.put_highlight(state, pid, updated)
    {new_state, []}
  end

  @spec handle_injection_ranges(EditorState.t(), pid() | nil, non_neg_integer(), term()) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_injection_ranges(state, nil, buffer_id, _ranges) do
    {state,
     [
       {:log, :editor, :warning,
        "injection_ranges for unknown buffer_id=#{buffer_id}, discarding"}
     ]}
  end

  defp handle_injection_ranges(state, pid, _buffer_id, ranges) do
    new_state = %{
      state
      | workspace: %{
          state.workspace
          | injection_ranges: Map.put(state.workspace.injection_ranges, pid, ranges)
        }
    }

    {new_state, []}
  end

  @spec handle_highlight_spans(
          EditorState.t(),
          pid() | nil,
          non_neg_integer(),
          non_neg_integer(),
          term()
        ) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_highlight_spans(state, nil, buffer_id, _version, _spans) do
    {state,
     [
       {:log, :editor, :warning, "highlight_spans for unknown buffer_id=#{buffer_id}, discarding"}
     ]}
  end

  defp handle_highlight_spans(state, pid, _buffer_id, version, spans)
       when pid == state.workspace.buffers.active do
    # Active buffer: delegate to HighlightEvents which calls HighlightSync
    # and renders. We need to replicate the logic but return effects.
    new_state = HighlightSync.handle_spans(state, version, spans)

    # Build effects for prettify symbols and render
    effects = [{:prettify_symbols, pid}, :render]

    # Check if we need to update agent styled cache
    agent_buf = AgentAccess.agent(new_state).buffer

    effects =
      if pid == agent_buf do
        effects ++ [{:update_agent_styled_cache}]
      else
        effects
      end

    {new_state, effects}
  end

  defp handle_highlight_spans(state, pid, _buffer_id, version, spans) do
    # Non-active buffer: store spans in highlights map
    existing = HighlightSync.get_highlight(state, pid)
    updated = Minga.UI.Highlight.put_spans(existing, version, spans)
    state_with_hl = HighlightSync.put_highlight(state, pid, updated)

    # If visible in any window, render
    effects =
      if buffer_visible_in_window?(state_with_hl, pid) do
        [:render]
      else
        []
      end

    # Check agent buffer styled cache
    agent_buf = AgentAccess.agent(state_with_hl).buffer

    effects =
      if pid == agent_buf do
        effects ++ [{:update_agent_styled_cache}]
      else
        effects
      end

    {state_with_hl, effects}
  end

  @spec handle_conceal_spans(EditorState.t(), pid() | nil, non_neg_integer(), [map()]) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_conceal_spans(state, nil, buffer_id, _spans) do
    {state,
     [{:log, :editor, :warning, "conceal_spans for unknown buffer_id=#{buffer_id}, discarding"}]}
  end

  defp handle_conceal_spans(state, pid, _buffer_id, spans) do
    {state, [{:conceal_spans, pid, spans}]}
  end

  @spec handle_fold_ranges(EditorState.t(), pid() | nil, non_neg_integer(), [
          {non_neg_integer(), non_neg_integer()}
        ]) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_fold_ranges(state, nil, buffer_id, _ranges) do
    {state,
     [
       {:log, :editor, :warning, "fold_ranges for unknown buffer_id=#{buffer_id}, discarding"}
     ]}
  end

  defp handle_fold_ranges(state, pid, _buffer_id, ranges)
       when pid == state.workspace.buffers.active do
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
       "Fold ranges received: buffer=#{inspect(pid)}, count=#{length(ranges)}"}
    ]

    {new_state, effects}
  end

  defp handle_fold_ranges(state, _pid, _buffer_id, _ranges) do
    # Response for a non-active buffer; discard.
    {state, []}
  end

  @spec handle_textobject_positions(EditorState.t(), pid() | nil, non_neg_integer(), map()) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_textobject_positions(state, nil, buffer_id, _positions) do
    {state,
     [
       {:log, :editor, :warning,
        "textobject_positions for unknown buffer_id=#{buffer_id}, discarding"}
     ]}
  end

  defp handle_textobject_positions(state, pid, _buffer_id, positions)
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

  defp handle_textobject_positions(state, _pid, _buffer_id, _positions) do
    # Response for a non-active buffer; discard.
    {state, []}
  end

  @spec handle_request_reparse(EditorState.t(), non_neg_integer()) ::
          {EditorState.t(), [highlight_effect()]}
  defp handle_request_reparse(state, buffer_id) do
    case HighlightSync.resolve_buffer_pid(state, buffer_id) do
      nil ->
        {state, []}

      buf_pid ->
        new_state =
          if buf_pid == state.workspace.buffers.active do
            HighlightSync.setup_for_buffer(state)
          else
            HighlightSync.request_reparse_buffer(state, buf_pid)
          end

        {new_state,
         [{:log, :editor, :info, "Parser requested full reparse for buffer #{buffer_id}"}]}
    end
  end

  @spec handle_parser_restarted(EditorState.t()) :: {EditorState.t(), [highlight_effect()]}
  defp handle_parser_restarted(state) do
    hl = state.workspace.highlight

    reset_highlights =
      Map.new(hl.highlights, fn {pid, buf_hl} ->
        {pid, %{buf_hl | version: 0}}
      end)

    new_state = %{
      state
      | workspace: %{
          state.workspace
          | highlight: %{hl | version: 0, highlights: reset_highlights}
        },
        parser_status: :available
    }

    {new_state, [{:log_message, "Parser restarted, syntax highlighting recovered"}]}
  end

  @spec handle_evict_parser_trees(EditorState.t()) :: {EditorState.t(), [highlight_effect()]}
  defp handle_evict_parser_trees(state) do
    ttl_seconds = Minga.Config.get(:parser_tree_ttl)
    agent_buf = state |> AgentAccess.agent() |> Map.get(:buffer)
    protected = if is_pid(agent_buf), do: [agent_buf], else: []

    new_state =
      HighlightSync.evict_inactive(state,
        ttl_ms: ttl_seconds * 1_000,
        protected_pids: protected
      )

    effects =
      if state.backend != :headless do
        [{:evict_parser_trees_timer}]
      else
        []
      end

    {new_state, effects}
  end

  # Returns true if the given buffer PID is visible in any window.
  @spec buffer_visible_in_window?(EditorState.t(), pid()) :: boolean()
  defp buffer_visible_in_window?(state, buf_pid) do
    Enum.any?(state.workspace.windows.map, fn {_id, win} -> win.buffer == buf_pid end)
  end
end
