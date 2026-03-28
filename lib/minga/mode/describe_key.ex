defmodule Minga.Mode.DescribeKey do
  @moduledoc """
  State for the describe-key meta-mode.

  When active, describe-key intercepts all input to walk the keymap
  trie and report the binding at the terminal node. The three fields
  (`leader_node`, `keys`) always change together: entering describe-key
  sets `leader_node` to the trie root, and exiting (via match, escape,
  or unbound key) resets both fields by replacing the struct with `nil`.
  """

  alias Minga.Keymap.Bindings

  @type t :: %__MODULE__{
          leader_node: Bindings.node_t() | nil,
          keys: [String.t()]
        }

  defstruct leader_node: nil,
            keys: []
end
