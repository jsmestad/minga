defmodule Minga.Editor.HighlightEvents do
  @moduledoc """
  Handles highlight-related messages from the Parser.Manager.

  Extracted from `Minga.Editor` to keep the GenServer module focused on
  orchestration. Each function takes state and returns `{:noreply, state}`.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.BufferLifecycle
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.Renderer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Git.Tracker, as: GitTracker

  @doc """
  Handles `:highlight_names` events from the parser.
  """
  @spec handle_names(EditorState.t(), [String.t()]) :: EditorState.t()
  def handle_names(state, names) do
    HighlightSync.handle_names(state, names)
  end

  @doc """
  Handles `:injection_ranges` events from the parser.
  """
  @spec handle_injection_ranges(EditorState.t(), term()) :: EditorState.t()
  def handle_injection_ranges(state, ranges) do
    if state.buffers.active do
      %{state | injection_ranges: Map.put(state.injection_ranges, state.buffers.active, ranges)}
    else
      state
    end
  end

  @doc """
  Handles `:highlight_spans` events from the parser.

  Updates the highlight state, caches spans for the active buffer,
  and triggers a render.
  """
  @spec handle_spans(EditorState.t(), non_neg_integer(), term()) :: EditorState.t()
  def handle_spans(state, version, spans) do
    new_state = HighlightSync.handle_spans(state, version, spans)

    new_state =
      if new_state.buffers.active do
        hl = new_state.highlight

        %{
          new_state
          | highlight: %{hl | cache: Map.put(hl.cache, new_state.buffers.active, hl.current)}
        }
      else
        new_state
      end

    Renderer.render(new_state)
  end

  @doc """
  Detects buffer switch and restores/caches highlights accordingly.

  Saves current highlights for the old buffer, restores cached highlights
  for the new buffer, or schedules highlight setup if no cache exists.
  """
  @spec maybe_reset_highlight(EditorState.t(), pid() | nil) :: EditorState.t()
  def maybe_reset_highlight(state, old_buffer) do
    new_buffer = state.buffers.active

    if new_buffer != old_buffer and new_buffer != nil do
      hl = state.highlight

      cache =
        if old_buffer != nil and hl.current.capture_names != [] do
          Map.put(hl.cache, old_buffer, hl.current)
        else
          hl.cache
        end

      case Map.get(cache, new_buffer) do
        nil ->
          send(self(), :setup_highlight)

          %{
            state
            | highlight: %{hl | current: Minga.Highlight.from_theme(state.theme), cache: cache}
          }

        cached ->
          %{state | highlight: %{hl | current: cached, cache: cache}}
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
        if buf, do: GitTracker.notify_change(buf)
        BufferLifecycle.lsp_buffer_changed(state)
      else
        state
      end

    if content_changed and state.highlight.current.capture_names != [] do
      HighlightSync.request_reparse(state)
    else
      state
    end
  end

  @spec buffer_version(EditorState.t()) :: non_neg_integer()
  defp buffer_version(%{buffers: %{active: nil}}), do: 0
  defp buffer_version(%{buffers: %{active: buf}}), do: BufferServer.version(buf)
end
