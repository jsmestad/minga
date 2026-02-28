defmodule Minga.Mode.State do
  @moduledoc """
  Base FSM state for the editor's modal system.

  Carries the shared fields used across all modes: the accumulated count
  prefix and leader-key sequence state. Normal mode uses this struct
  directly; other modes define their own structs that include these fields
  plus mode-specific context.
  """

  alias Minga.Keymap.Trie

  @enforce_keys []
  defstruct count: nil,
            leader_node: nil,
            leader_keys: [],
            pending_g: false,
            pending_find: nil,
            pending_replace: false

  @typedoc "Pending find-char direction."
  @type find_direction :: :f | :F | :t | :T

  @type t :: %__MODULE__{
          count: non_neg_integer() | nil,
          leader_node: Trie.node_t() | nil,
          leader_keys: [String.t()],
          pending_g: boolean(),
          pending_find: find_direction() | nil,
          pending_replace: boolean()
        }
end
