defmodule Minga.Mode.OperatorPendingState do
  @moduledoc """
  FSM state for Operator-Pending mode.

  Carries the pending operator (delete/change/yank), the count prefix
  accumulated before the operator key, and text-object/g-prefix tracking.
  """

  @enforce_keys [:operator]
  defstruct operator: nil,
            op_count: 1,
            count: nil,
            pending_g: false,
            text_object_modifier: nil,
            leader_node: nil,
            leader_keys: []

  @typedoc "The pending operator."
  @type operator :: :delete | :change | :yank

  @typedoc "Text object modifier (inner vs around)."
  @type text_object_modifier :: :inner | :around

  @type t :: %__MODULE__{
          operator: operator(),
          op_count: pos_integer(),
          count: non_neg_integer() | nil,
          pending_g: boolean(),
          text_object_modifier: text_object_modifier() | nil,
          leader_node: Minga.Keymap.Trie.node_t() | nil,
          leader_keys: [String.t()]
        }
end
