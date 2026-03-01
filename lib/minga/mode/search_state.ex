defmodule Minga.Mode.SearchState do
  @moduledoc """
  FSM state for Search mode (`/` and `?`).

  Tracks the accumulated search input, direction, and the cursor position
  before the search started (for restore on Escape).
  """

  @enforce_keys [:direction]
  defstruct input: "",
            direction: :forward,
            original_cursor: {0, 0},
            count: nil

  @typedoc "Search direction."
  @type direction :: :forward | :backward

  @type t :: %__MODULE__{
          input: String.t(),
          direction: direction(),
          original_cursor: {non_neg_integer(), non_neg_integer()},
          count: non_neg_integer() | nil
        }
end
