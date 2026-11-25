defmodule Minga.Mode.SearchState do
  @moduledoc """
  FSM state for Search mode (`/` and `?`).

  Tracks the accumulated search input, direction, and the cursor position
  before the search started (for restore on Escape).

  It also records whether the input matches nothing in the buffer, so the prompt can say so while you type.
  """

  @enforce_keys [:direction]
  defstruct input: "",
            direction: :forward,
            original_cursor: {0, 0},
            count: nil,
            no_match?: false

  @typedoc "Search direction."
  @type direction :: :forward | :backward

  @type t :: %__MODULE__{
          input: String.t(),
          direction: direction(),
          original_cursor: {non_neg_integer(), non_neg_integer()},
          count: non_neg_integer() | nil,
          no_match?: boolean()
        }

  @doc "Records whether the input matches anything in the buffer."
  @spec record_match(t(), boolean()) :: t()
  def record_match(%__MODULE__{} = state, found?) when is_boolean(found?),
    do: %{state | no_match?: not found?}
end
