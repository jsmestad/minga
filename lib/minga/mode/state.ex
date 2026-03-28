defmodule Minga.Mode.State do
  @moduledoc """
  Base FSM state for the editor's modal system.

  Carries the shared fields used across all modes: the accumulated count
  prefix, leader-key sequence state, and a `pending` tagged union for
  single-key completion operations. Normal mode uses this struct directly;
  other modes define their own structs that include these fields plus
  mode-specific context.

  ## Pending operations

  The `pending` field is a tagged union encoding the mutually exclusive
  single-key operations (find-char, replace, mark, register, macro
  record/replay). At most one can be active at a time, and the type
  system enforces this: `pending` is either a tagged value or `nil`.

  ## Describe-key mode

  The `describe_key` field holds state for the describe-key meta-mode,
  which intercepts all input to walk the keymap trie and report bindings.
  When `nil`, describe-key is inactive. When set, it contains the current
  trie node and accumulated key sequence.
  """

  alias Minga.Keymap.Bindings
  alias Minga.Mode.DescribeKey

  @typedoc "Pending find-char direction."
  @type find_direction :: :f | :F | :t | :T

  @typedoc "Pending mark operation kind."
  @type pending_mark_kind :: :set | :jump_line | :jump_exact

  @typedoc """
  A single-key completion operation waiting for the next keystroke.

  At most one can be active at a time. `nil` means no pending operation.
  """
  @type pending ::
          {:find, find_direction()}
          | :replace
          | {:mark, pending_mark_kind()}
          | :register
          | :macro_register
          | :macro_replay
          | nil

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
          pending: pending(),
          describe_key: DescribeKey.t() | nil
        }

  defstruct filetype: :text,
            count: nil,
            leader_trie: nil,
            normal_bindings: %{},
            mode_trie: nil,
            leader_node: nil,
            leader_keys: [],
            prefix_node: nil,
            prefix_keys: [],
            pending: nil,
            describe_key: nil
end
