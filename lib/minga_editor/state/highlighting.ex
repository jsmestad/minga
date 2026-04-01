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
end
