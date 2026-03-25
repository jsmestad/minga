defmodule Minga.Agent.Instruction do
  @moduledoc """
  A single system instruction loaded from a file.

  Instructions provide context to the agent (project rules, coding standards,
  skill definitions). Each carries a human-readable label, the source file path,
  and the file's content. Built by `Agent.Instructions` and consumed by
  provider modules when constructing the system prompt.
  """

  @typedoc "An agent instruction."
  @type t :: %__MODULE__{
          label: String.t(),
          path: String.t(),
          content: String.t()
        }

  @enforce_keys [:label, :path, :content]
  defstruct label: nil,
            path: nil,
            content: nil
end
