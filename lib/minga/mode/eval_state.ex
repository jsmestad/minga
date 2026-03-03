defmodule Minga.Mode.EvalState do
  @moduledoc """
  FSM state for Eval (`M-:`) mode.

  Carries the eval input string typed so far, plus the standard
  count/leader fields.
  """

  @enforce_keys []
  defstruct input: "",
            count: nil,
            leader_node: nil,
            leader_keys: []

  @type t :: %__MODULE__{
          input: String.t(),
          count: non_neg_integer() | nil,
          leader_node: Minga.Keymap.Trie.node_t() | nil,
          leader_keys: [String.t()]
        }
end
