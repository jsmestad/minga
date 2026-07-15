defmodule Minga.Credo.EditorStateOwnership.Ownership do
  @moduledoc """
  A validated value-owner declaration consumed by EX9012 rules.

  Keeping this shape typed prevents each rule from interpreting raw Credo
  keyword parameters independently.
  """

  @enforce_keys [:struct, :owners, :paths, :pure?, :generic_api?, :boundary, :workflow]
  defstruct [:struct, :owners, :paths, :pure?, :generic_api?, :boundary, :workflow]

  @type t :: %__MODULE__{
          struct: String.t(),
          owners: [String.t(), ...],
          paths: [[atom()]],
          pure?: boolean(),
          generic_api?: boolean(),
          boundary: String.t(),
          workflow: String.t()
        }
end
