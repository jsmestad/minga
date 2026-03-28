defmodule Minga.Mode.State do
  @moduledoc """
  Base FSM state for the editor's modal system.

  Carries the shared fields used across all modes: the accumulated count
  prefix and leader-key sequence state. Normal mode uses this struct
  directly; other modes define their own structs that include these fields
  plus mode-specific context.
  """

  alias Minga.Keymap.Bindings

  defstruct filetype: :text,
            count: nil,
            leader_trie: nil,
            normal_bindings: %{},
            mode_trie: nil,
            leader_node: nil,
            leader_keys: [],
            prefix_node: nil,
            prefix_keys: [],
            pending_find: nil,
            pending_replace: false,
            pending_mark: nil,
            pending_register: false,
            pending_macro_register: false,
            pending_macro_replay: false,
            pending_describe_key: false,
            describe_key_leader_node: nil,
            describe_key_keys: []

  @typedoc "Pending find-char direction."
  @type find_direction :: :f | :F | :t | :T

  @typedoc "Pending mark operation kind."
  @type pending_mark_kind :: :set | :jump_line | :jump_exact

  @typedoc "Single-key normal bindings map: key => {command, description}."
  @type normal_bindings_map :: %{Bindings.key() => {atom(), String.t()}}

  @type t :: %__MODULE__{
          filetype: atom(),
          count: non_neg_integer() | nil,
          leader_trie: Bindings.node_t() | nil,
          normal_bindings: normal_bindings_map(),
          mode_trie: Bindings.node_t() | nil,
          leader_node: Bindings.node_t() | nil,
          leader_keys: [String.t()],
          prefix_node: Bindings.node_t() | nil,
          prefix_keys: [String.t()],
          pending_find: find_direction() | nil,
          pending_replace: boolean(),
          pending_mark: pending_mark_kind() | nil,
          pending_register: boolean(),
          pending_macro_register: boolean(),
          pending_macro_replay: boolean(),
          pending_describe_key: boolean(),
          describe_key_leader_node: Bindings.node_t() | nil,
          describe_key_keys: [String.t()]
        }
end
