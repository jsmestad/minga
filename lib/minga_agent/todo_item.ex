defmodule MingaAgent.TodoItem do
  @moduledoc "One stable, inspectable task in an Agent session's checklist."

  alias MingaAgent.Tool.Output.Reference
  @typedoc "Todo item status."
  @type status :: :pending | :in_progress | :blocked | :done

  @typedoc "A todo item."
  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t(),
          status: status(),
          note: String.t() | nil,
          result_ref: Reference.t() | nil
        }

  @enforce_keys [:id, :description]
  defstruct id: nil,
            description: nil,
            status: :pending,
            note: nil,
            result_ref: nil
end
