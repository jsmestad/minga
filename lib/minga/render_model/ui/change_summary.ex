defmodule Minga.RenderModel.UI.ChangeSummary do
  @moduledoc """
  Semantic change summary model.

  Describes the diff-stat entries shown for an agent change summary: per-file path,
  change action, and added/removed line counts, plus the currently selected
  entry index. An empty `entries` list means the surface is hidden.

  This is pure data with domain fields. The GUI adapter
  (`Minga.Frontend.Adapter.GUI.ChangeSummaryEncoder`) owns the wire encoding.
  """

  alias __MODULE__.Entry

  @type t :: %__MODULE__{
          entries: [Entry.t()],
          selected_index: non_neg_integer()
        }

  defstruct entries: [], selected_index: 0

  defmodule Entry do
    @moduledoc """
    One diff-stat row in a change summary: a file path, its change action, and
    the number of lines added and removed.
    """

    @type action :: :modified | :added | :deleted | :renamed

    @type t :: %__MODULE__{
            path: String.t(),
            action: action(),
            lines_added: non_neg_integer(),
            lines_removed: non_neg_integer()
          }

    @enforce_keys [:path]
    defstruct [:path, action: :modified, lines_added: 0, lines_removed: 0]
  end
end
