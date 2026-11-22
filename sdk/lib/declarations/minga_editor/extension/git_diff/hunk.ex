defmodule MingaEditor.Extension.GitDiff.Hunk do
  @moduledoc """
  One change at the rendered diff cursor, independent of the layout.

  `index` is one-based. Change coordinates are zero-based in the base (`old_*`)
  and revised texts. Empty text has no lines; nonempty text is split on `"\n"`
  without trimming the trailing empty row. A deletion has `count: 0`.
  """

  @enforce_keys [:index, :total, :change]
  defstruct [:index, :total, :change]

  @type change :: %{
          type: :added | :modified | :deleted,
          start_line: non_neg_integer(),
          count: non_neg_integer(),
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          old_lines: [String.t()]
        }

  @type t :: %__MODULE__{
          index: pos_integer(),
          total: pos_integer(),
          change: change()
        }
end
