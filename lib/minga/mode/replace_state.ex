defmodule Minga.Mode.ReplaceState do
  @moduledoc """
  FSM state for Replace mode.

  Carries a stack of original characters that were overwritten, used to
  restore them when the user presses Backspace.

  ## Fields

  * `original_chars` — stack (list) of characters saved before overwriting.
    The most-recently saved character is at the head of the list.
    When the stack is empty, Backspace is a no-op (Vim behaviour: cannot
    backspace past the column at which Replace mode was entered).
  """

  defstruct original_chars: [],
            count: nil,
            leader_node: nil,
            leader_keys: []

  @type t :: %__MODULE__{
          original_chars: [String.t()],
          count: non_neg_integer() | nil,
          leader_node: Minga.Keymap.Bindings.node_t() | nil,
          leader_keys: [String.t()]
        }
end
