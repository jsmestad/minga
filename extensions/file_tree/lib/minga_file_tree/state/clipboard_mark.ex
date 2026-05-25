defmodule MingaFileTree.State.ClipboardMark do
  @moduledoc """
  Pending file tree copy or move operation.

  The mark stores the selected source entry until the user chooses a paste destination.
  """

  @type operation :: :copy | :move

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          dir?: boolean(),
          operation: operation()
        }

  @enforce_keys [:path, :name, :dir?, :operation]
  defstruct [:path, :name, :dir?, :operation]

  @doc "Builds a clipboard mark for a file tree entry."
  @spec new(String.t(), String.t(), boolean(), operation()) :: t()
  def new(path, name, dir?, operation)
      when is_binary(path) and is_binary(name) and is_boolean(dir?) and
             operation in [:copy, :move] do
    %__MODULE__{path: path, name: name, dir?: dir?, operation: operation}
  end
end
