defmodule MingaAgent.TodoItem do
  @moduledoc """
  A single todo item in the agent's internal task list.

  The agent uses todos to track progress on multi-step operations.
  Each item has a unique id, a description, and a status that progresses
  from `:pending` through `:in_progress` to `:done`.
  """

  @typedoc "Todo item status."
  @type status :: :pending | :in_progress | :done

  @typedoc "A todo item."
  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t(),
          status: status()
        }

  @enforce_keys [:id, :description]
  defstruct id: nil,
            description: nil,
            status: :pending
end
