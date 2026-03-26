defmodule Minga.Mode.SubstituteConfirmState do
  @moduledoc """
  FSM state for substitute confirm mode (`:%s/old/new/gc`).

  Tracks the list of matches, the current match index, the pattern and
  replacement strings, the original buffer content, and which matches
  the user has accepted for replacement.
  """

  @enforce_keys [:matches, :pattern, :replacement, :original_content]
  defstruct matches: [],
            current: 0,
            pattern: "",
            replacement: "",
            original_content: "",
            accepted: [],
            count: nil

  @typedoc "A match position: `{line, col, length}`."
  @type match_pos :: Minga.Editing.Search.Match.t()

  @type t :: %__MODULE__{
          matches: [match_pos()],
          current: non_neg_integer(),
          pattern: String.t(),
          replacement: String.t(),
          original_content: String.t(),
          accepted: [non_neg_integer()],
          count: non_neg_integer() | nil
        }
end
