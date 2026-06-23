defmodule Minga.RenderModel.UI.EditTimeline.FileEntry do
  @moduledoc false

  @type review_status :: :pending | :reviewing

  @type t :: %__MODULE__{
          path: String.t(),
          entry_count: pos_integer(),
          lines_added: non_neg_integer(),
          lines_removed: non_neg_integer(),
          review_status: review_status()
        }

  @enforce_keys [:path, :entry_count]
  defstruct [:path, :entry_count, lines_added: 0, lines_removed: 0, review_status: :pending]
end
