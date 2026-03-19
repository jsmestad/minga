defmodule Minga.Editor.HighlightEvents do
  @moduledoc """
  Handles highlight-related messages from the Parser.Manager.

  Extracted from `Minga.Editor` to keep the GenServer module focused on
  orchestration. Each function takes state and returns updated state.

  With per-buffer tree-sitter parsing, highlight data is stored per-buffer
  in `highlight.highlights`. There is no separate "current" field.
  """

  alias Minga.Buffer.Server, as: BufferServer

  alias Minga.Editor.HighlightSync
  alias Minga.Editor.Renderer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Filetype
  alias Minga.Git.Tracker, as: GitTracker
  alias Minga.LSP.SyncServer
  alias Minga.PrettifySymbols

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
    new_buffer = state.buffers.active

    if new_buffer != old_buffer and new_buffer != nil do
      hl = state.highlight

      case Map.get(hl.highlights, new_buffer) do
        nil ->
          # New buffer with no highlights: schedule setup.
          send(self(), :setup_highlight)
          state

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

    state =
      if content_changed do
        buf = state.buffers.active

        if buf do
          Minga.Events.broadcast(:buffer_changed, %Minga.Events.BufferChangedEvent{buffer: buf})
          SyncServer.notify_change(buf)
          GitTracker.notify_change(buf)
        end

        state
      else
        state
      end

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

  # Applies prettify-symbol conceals after highlights update.
  # Skips entirely when the feature is disabled (the default) to avoid
  # spawning a Task on every highlight event.
  @spec maybe_apply_prettify_symbols(EditorState.t()) :: :ok
  defp maybe_apply_prettify_symbols(%{buffers: %{active: nil}}), do: :ok

  defp maybe_apply_prettify_symbols(state) do
    if PrettifySymbols.enabled?() do
      buf = state.buffers.active
      hl = HighlightSync.get_active_highlight(state)

      if hl.capture_names != {} and tuple_size(hl.spans) > 0 do
        file_path = BufferServer.file_path(buf)
        filetype = Filetype.detect(file_path)

        Task.start(fn ->
          PrettifySymbols.apply(buf, hl, filetype)
        end)
      end
    end

    :ok
  end

  @spec buffer_version(EditorState.t()) :: non_neg_integer()
  defp buffer_version(%{buffers: %{active: nil}}), do: 0
  defp buffer_version(%{buffers: %{active: buf}}), do: BufferServer.version(buf)
end
