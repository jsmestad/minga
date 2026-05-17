defmodule MingaEditor.State.Highlighting do
  @moduledoc """
  Groups syntax-highlighting fields from EditorState.

  Tracks per-buffer highlight data, a monotonic version counter for
  invalidation, the mapping from buffer PIDs to parser buffer IDs
  (monotonically incrementing u32s), and LRU timestamps for inactive
  tree eviction.

  Highlight spans are stored per-buffer in `highlights`. There is no
  separate "current" field; the active buffer's highlight is just
  `Map.get(highlights, active_pid)`.
  """

  alias MingaEditor.UI.Highlight

  @type t :: %__MODULE__{
          highlights: %{pid() => Highlight.t()},
          version: non_neg_integer(),
          buffer_ids: %{pid() => non_neg_integer()},
          reverse_buffer_ids: %{non_neg_integer() => pid()},
          next_buffer_id: non_neg_integer(),
          last_active_at: %{pid() => integer()},
          syntax_overrides: %{pid() => MingaEditor.UI.Theme.syntax()}
        }

  defstruct highlights: %{},
            version: 0,
            buffer_ids: %{},
            reverse_buffer_ids: %{},
            next_buffer_id: 1,
            last_active_at: %{},
            syntax_overrides: %{}

  @doc "Sets the highlight state version."
  @spec set_version(t(), non_neg_integer()) :: t()
  def set_version(%__MODULE__{} = state, version) when is_integer(version) and version >= 0 do
    %{state | version: version}
  end

  @doc "Replaces syntax overrides."
  @spec set_syntax_overrides(t(), %{pid() => MingaEditor.UI.Theme.syntax()}) :: t()
  def set_syntax_overrides(%__MODULE__{} = state, overrides) when is_map(overrides) do
    %{state | syntax_overrides: overrides}
  end

  @doc "Stores highlight data for a buffer."
  @spec put_highlight(t(), pid(), Highlight.t()) :: t()
  def put_highlight(%__MODULE__{} = state, pid, highlight) do
    %{state | highlights: Map.put(state.highlights, pid, highlight)}
  end

  @doc "Replaces the highlight map."
  @spec set_highlights(t(), %{pid() => Highlight.t()}) :: t()
  def set_highlights(%__MODULE__{} = state, highlights) when is_map(highlights) do
    %{state | highlights: highlights}
  end

  @doc "Removes all highlight-related state for a buffer."
  @spec remove_buffer(t(), pid(), non_neg_integer(), %{pid() => non_neg_integer()}) :: t()
  def remove_buffer(%__MODULE__{} = state, buffer_pid, buffer_id, remaining_ids) do
    %{
      state
      | buffer_ids: remaining_ids,
        reverse_buffer_ids: Map.delete(state.reverse_buffer_ids, buffer_id),
        highlights: Map.delete(state.highlights, buffer_pid),
        last_active_at: Map.delete(state.last_active_at, buffer_pid),
        syntax_overrides: Map.delete(state.syntax_overrides, buffer_pid)
    }
  end
end
