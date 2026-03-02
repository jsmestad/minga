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
            pending_replace: false,
            pending_mark: nil,
            pending_register: false,
            pending_macro_register: false,
            pending_macro_replay: false

  @typedoc "Pending find-char direction."
  @type find_direction :: :f | :F | :t | :T

  @typedoc "Pending mark operation kind."
  @type pending_mark_kind :: :set | :jump_line | :jump_exact

  @type t :: %__MODULE__{
          count: non_neg_integer() | nil,
          leader_node: Trie.node_t() | nil,
          leader_keys: [String.t()],
          pending_g: boolean(),
          pending_find: find_direction() | nil,
          pending_replace: boolean(),
          pending_mark: pending_mark_kind() | nil,
          pending_register: boolean(),
          pending_macro_register: boolean(),
          pending_macro_replay: boolean()
        }
end
