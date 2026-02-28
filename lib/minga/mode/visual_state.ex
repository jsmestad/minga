defmodule Minga.Mode.VisualState do
  @moduledoc """
  FSM state for Visual mode.

  Carries the selection type (characterwise or linewise), the fixed anchor
  position of the selection, and the standard count/leader fields.
  """

  @enforce_keys [:visual_type]
  defstruct visual_type: :char,
            visual_anchor: {0, 0},
            count: nil,
            leader_node: nil,
            leader_keys: []

  @typedoc "Selection type: characterwise or linewise."
  @type selection_type :: :char | :line

  @type t :: %__MODULE__{
          visual_type: selection_type(),
          visual_anchor: {non_neg_integer(), non_neg_integer()},
          count: non_neg_integer() | nil,
          leader_node: Minga.Keymap.Trie.node_t() | nil,
          leader_keys: [String.t()]
        }
end
