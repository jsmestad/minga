defmodule Minga.Editor.HighlightEvents do
  @moduledoc """
  Handles highlight-related messages from the Parser.Manager.

  Extracted from `Minga.Editor` to keep the GenServer module focused on
  orchestration. Each function takes state and returns updated state.

  With per-buffer tree-sitter parsing, highlight data is stored per-buffer
  in `highlight.highlights`. There is no separate "current" field.
  """

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.Renderer
  alias Minga.Editor.SemanticTokenSync
  alias Minga.Editor.State, as: EditorState
  alias Minga.Language
  alias Minga.UI.PrettifySymbols

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
    maybe_apply_prettify_symbols(new_state)
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
      hl = state.workspace.highlight

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

  @doc """
  Re-parses the buffer for syntax highlighting if content changed.

  Compares the buffer's mutation version before/after key handling.
  Also notifies LSP and Git of the content change.
  """
  @spec maybe_reparse(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def maybe_reparse(state, version_before) do
    content_changed = buffer_version(state) != version_before

    # Buffer.Server now broadcasts :buffer_changed with delta from record_edit.
    # No need to call notify_buffer_changed here.

    if content_changed do
      active_hl = HighlightSync.get_active_highlight(state)

      if active_hl.capture_names != {} do
        HighlightSync.request_reparse(state)
      else
        state
      end
    else
      state
    end
  end

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

  # Applies prettify-symbol conceals after highlights update.
  # Skips entirely when the feature is disabled (the default) to avoid
  # spawning a Task on every highlight event.
  @spec maybe_apply_prettify_symbols(EditorState.t()) :: :ok
  defp maybe_apply_prettify_symbols(%{workspace: %{buffers: %{active: nil}}}), do: :ok

  defp maybe_apply_prettify_symbols(state) do
    if PrettifySymbols.enabled?() do
      spawn_prettify_task(state)
    end

    :ok
  end

  @spec spawn_prettify_task(EditorState.t()) :: :ok
  defp spawn_prettify_task(state) do
    buf = state.workspace.buffers.active
    hl = HighlightSync.get_active_highlight(state)

    if hl.capture_names != {} and tuple_size(hl.spans) > 0 do
      file_path = Buffer.file_path(buf)
      filetype = Language.detect_filetype(file_path)

      Task.start(fn ->
        PrettifySymbols.apply(buf, hl, filetype)
      end)
    end

    :ok
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

  @spec buffer_version(EditorState.t()) :: non_neg_integer()
  defp buffer_version(%{workspace: %{buffers: %{active: nil}}}), do: 0
  defp buffer_version(%{workspace: %{buffers: %{active: buf}}}), do: Buffer.version(buf)
end
