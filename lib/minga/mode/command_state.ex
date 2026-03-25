defmodule Minga.Mode.CommandState do
  @moduledoc """
  FSM state for Command (`:`) mode.

  Carries the command-line input string typed so far (without the leading
  `:`), plus the standard count/leader fields.
  """

  defstruct input: "",
            candidate_index: 0,
            count: nil,
            leader_node: nil,
            leader_keys: []

  @type t :: %__MODULE__{
          input: String.t(),
          candidate_index: integer(),
          count: non_neg_integer() | nil,
          leader_node: Minga.Keymap.Bindings.node_t() | nil,
          leader_keys: [String.t()]
        }
end
