defmodule Minga.Mode.SearchPromptState do
  @moduledoc """
  FSM state for the search prompt mode (project-wide search).

  Tracks the accumulated query input. Used by `SPC s p` / `SPC /` to
  collect a search query before running project search.
  """

  defstruct input: "",
            count: nil

  @type t :: %__MODULE__{
          input: String.t(),
          count: non_neg_integer() | nil
        }
end
