defmodule Minga.Session.BufferEntry do
  @moduledoc """
  A single buffer's state within a session snapshot.

  Captures the file path and cursor position so they can be restored
  when the session is reloaded.
  """

  @derive JSON.Encoder

  @typedoc "A buffer entry in the session snapshot."
  @type t :: %__MODULE__{
          file: String.t(),
          cursor_line: non_neg_integer(),
          cursor_col: non_neg_integer()
        }

  @enforce_keys [:file]
  defstruct file: nil,
            cursor_line: 0,
            cursor_col: 0
end
