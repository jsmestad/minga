defmodule Minga.RenderModel.UI.EditTimeline do
  @moduledoc """
  Semantic edit timeline model.

  Describes the per-buffer edit timeline: whether it is visible, which entry is
  currently being viewed (nil when live at the latest), and the timeline entries
  (tool name and a timestamp delta from the first entry). The GUI adapter
  (`Minga.Frontend.Adapter.GUI.EditTimelineEncoder`) owns the wire encoding.
  """

  alias __MODULE__.Entry
  alias __MODULE__.FileEntry

  @type t :: %__MODULE__{
          visible?: boolean(),
          viewing_index: non_neg_integer() | nil,
          entries: [Entry.t()],
          files: [FileEntry.t()]
        }

  defstruct visible?: false, viewing_index: nil, entries: [], files: []

  defmodule Entry do
    @moduledoc "One edit-timeline entry: its index, the tool that made the edit, and a delta from the first entry's timestamp."

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            tool_name: String.t(),
            timestamp_delta: non_neg_integer()
          }

    @enforce_keys [:index, :tool_name, :timestamp_delta]
    defstruct [:index, :tool_name, :timestamp_delta]
  end
end
