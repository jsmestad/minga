defmodule MingaAgent.Changeset.MergedEvent do
  @moduledoc "Payload for `:changeset_merged` events."
  @enforce_keys [:project_root, :modified, :deleted]
  defstruct [:project_root, :modified, :deleted]

  @type t :: %__MODULE__{
          project_root: String.t(),
          modified: [String.t()],
          deleted: [String.t()]
        }
end
