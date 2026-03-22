defmodule Minga.Mode.ToolConfirmState do
  @moduledoc """
  FSM state for the tool install confirmation prompt.

  Holds a queue of missing tool names to prompt about sequentially,
  plus the set of tools the user has declined this session.
  """

  @enforce_keys [:pending]
  defstruct pending: [],
            current: 0,
            declined: MapSet.new(),
            count: nil

  @type t :: %__MODULE__{
          pending: [atom()],
          current: non_neg_integer(),
          declined: MapSet.t(atom()),
          count: non_neg_integer() | nil
        }
end
