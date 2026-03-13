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
  @type operator :: :comment | :delete | :change | :yank | :indent | :dedent | :reindent

  @typedoc "Text object modifier (inner vs around)."
  @type text_object_modifier :: :inner | :around

  @type t :: %__MODULE__{
          operator: operator(),
          op_count: pos_integer(),
          count: non_neg_integer() | nil,
          pending_g: boolean(),
          text_object_modifier: text_object_modifier() | nil,
          leader_node: Minga.Keymap.Bindings.node_t() | nil,
          leader_keys: [String.t()]
        }

  @doc "Creates a new operator-pending state."
  @spec new(operator(), pos_integer()) :: t()
  def new(operator, op_count \\ 1) do
    %__MODULE__{operator: operator, op_count: op_count}
  end

  @doc """
  Total repeat count: `op_count` (from before the operator key) × motion count.

  For example, `3dw` has `op_count=3` and `count=nil` (motion count defaults to 1),
  so `total_count/1` returns 3. `d2w` has `op_count=1` and `count=2`, returning 2.
  """
  @spec total_count(t()) :: pos_integer()
  def total_count(%__MODULE__{op_count: op_count, count: count}) do
    op_count * (count || 1)
  end

  @doc """
  Converts operator-pending state back to the base `Mode.State`,
  discarding all operator-specific fields.
  """
  @spec to_base_state(t()) :: Minga.Mode.State.t()
  def to_base_state(%__MODULE__{}) do
    %Minga.Mode.State{}
  end
end
