defmodule MingaAgent.Changeset.BudgetExhaustedEvent do
  @moduledoc "Payload for `:changeset_budget_exhausted` events."
  @enforce_keys [:project_root, :attempts, :budget]
  defstruct [:project_root, :attempts, :budget]

  @type t :: %__MODULE__{
          project_root: String.t(),
          attempts: pos_integer(),
          budget: pos_integer()
        }
end
