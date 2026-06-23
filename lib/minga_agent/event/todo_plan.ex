defmodule MingaAgent.Event.TodoPlan do
  @moduledoc false

  alias MingaAgent.TodoItem

  @type t :: %__MODULE__{
          todos: [TodoItem.t()]
        }

  @enforce_keys [:todos]
  defstruct [:todos]
end
