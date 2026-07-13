defmodule MingaEditor.HighlightEvents do
  @moduledoc """
  Handles highlight-related messages from the Parser.Manager.

  Extracted from `MingaEditor` to keep the GenServer module focused on
  orchestration. Each function takes state and returns updated state.

  With per-buffer tree-sitter parsing, highlight data is stored per-buffer
  in `highlight.highlights`. There is no separate "current" field.
  """

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias MingaEditor.HighlightSync
  alias MingaEditor.Renderer
  alias MingaEditor.SemanticTokenSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.PrettifySymbolsEffect

  @doc """
  Handles `:highlight_names` events from the parser (for the active buffer).
  """
  @spec handle_names(EditorState.t(), [String.t()]) :: EditorState.t()
  def handle_names(state, names) do
    HighlightSync.handle_names(state, names)
  end

  @doc """
  Handles `:highlight_spans` events from the parser (for the active buffer).

  Updates the buffer's highlight data and triggers a render.
  """
  @spec handle_spans(EditorState.t(), non_neg_integer(), term()) :: EditorState.t()
  def handle_spans(state, version, spans) do
    new_state = HighlightSync.handle_spans(state, version, spans)
    buffer = new_state.workspace.buffers.active

    new_state =
      case buffer do
        pid when is_pid(pid) -> PrettifySymbolsEffect.schedule(new_state, pid)
        nil -> new_state
      end

    Renderer.render(new_state)
  end

  @doc """
  Detects buffer switch and schedules highlight setup if the new buffer
  has no cached highlights.

  With per-buffer parsing, buffer switches don't need to swap data in
  and out of a "current" field. Each buffer's highlights live in the
  `highlights` map permanently. We just need to trigger setup if the
  buffer has never been highlighted before.
  """
  @spec maybe_reset_highlight(EditorState.t(), pid() | nil) :: EditorState.t()
  def maybe_reset_highlight(state, old_buffer) do
    new_buffer = state.workspace.buffers.active

    if new_buffer != old_buffer and new_buffer != nil do
      hl = state.highlighting

      case Map.get(hl.highlights, new_buffer) do
        nil ->
          # New buffer with no highlights: in headless mode apply
          # synchronously; otherwise defer via self-send.
          setup_highlight_or_defer(state)

        _cached ->
          # Buffer has cached highlights: nothing to do, they're already
          # in the highlights map and will be read by the render pipeline.
          # Refresh the LRU timestamp so actively-viewed buffers aren't evicted.
          HighlightSync.touch_active(state)
      end
    else
      state
    end
  end

  @doc "Returns editor presentation state unchanged; parser synchronization is event-driven."
  @spec maybe_reparse(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def maybe_reparse(state, _version_before), do: state

  @doc """
  Handles `:conceal_spans` events from the parser.

  Applies ConcealRange decorations from tree-sitter @conceal captures with
  `#set! conceal "X"` directives. Clears the `:ts_conceal` group before
  applying new conceals to handle re-parses correctly.
  """
  @spec handle_conceal_spans(EditorState.t(), pid(), [map()]) :: :ok
  def handle_conceal_spans(_state, buf, spans) when is_pid(buf) do
    content = Buffer.content(buf)
    lines = String.split(content, "\n")

    Buffer.batch_decorations(buf, fn decs ->
      decs
      |> Decorations.remove_conceal_group(:ts_conceal)
      |> add_conceal_spans(spans, lines)
    end)

    :ok
  end

  @spec add_conceal_spans(Decorations.t(), [map()], [String.t()]) :: Decorations.t()
  defp add_conceal_spans(decs, spans, lines) do
    Enum.reduce(spans, decs, fn span, acc ->
      {start_line, start_col} = byte_to_position(lines, span.start_byte)
      {end_line, end_col} = byte_to_position(lines, span.end_byte)
      replacement = if span.replacement == "", do: nil, else: span.replacement

      {_id, new_decs} =
        Decorations.add_conceal(acc, {start_line, start_col}, {end_line, end_col},
          replacement: replacement,
          replacement_style: %Face{name: "_"},
          group: :ts_conceal,
          priority: 5
        )

      new_decs
    end)
  end

  # Converts a byte offset to {line, col} position.
  @spec byte_to_position([String.t()], non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp byte_to_position(lines, byte_offset) do
    do_byte_to_position(lines, byte_offset, 0)
  end

  @spec do_byte_to_position([String.t()], non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp do_byte_to_position([], _remaining, line_idx), do: {max(line_idx - 1, 0), 0}

  defp do_byte_to_position([line | rest], remaining, line_idx) do
    line_bytes = byte_size(line) + 1

    if remaining < line_bytes do
      col = grapheme_col(line, remaining)
      {line_idx, col}
    else
      do_byte_to_position(rest, remaining - line_bytes, line_idx + 1)
    end
  end

  # Converts a byte offset within a line to a grapheme column.
  @spec grapheme_col(String.t(), non_neg_integer()) :: non_neg_integer()
  defp grapheme_col(line, byte_offset) do
    prefix = binary_part(line, 0, min(byte_offset, byte_size(line)))
    String.length(prefix)
  end

  # In headless mode, apply highlight setup synchronously; otherwise defer.
  @spec setup_highlight_or_defer(EditorState.t()) :: EditorState.t()
  defp setup_highlight_or_defer(%{backend: :headless} = state) do
    state = HighlightSync.setup_for_buffer(state)
    SemanticTokenSync.request_tokens(state)
  end

  defp setup_highlight_or_defer(state) do
    send(self(), :setup_highlight)
    state
  end
end
