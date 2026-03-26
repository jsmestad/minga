defmodule Minga.Editing.Snippet.Tabstop do
  @moduledoc """
  A single tabstop within a snippet.

  Tabstops mark positions where the cursor should jump during snippet
  expansion. Each has an index (the `$1`, `$2` numbering), a byte offset
  within the expanded snippet text, a length (for placeholder tabstops),
  and optional placeholder text.
  """

  @typedoc "A snippet tabstop."
  @type t :: %__MODULE__{
          index: non_neg_integer(),
          offset: non_neg_integer(),
          length: non_neg_integer(),
          placeholder: String.t()
        }

  @enforce_keys [:index, :offset]
  defstruct index: 0,
            offset: 0,
            length: 0,
            placeholder: ""
end
