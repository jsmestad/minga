defmodule MingaEditor.UI.Picker.FilesystemContext do
  @moduledoc "Immutable source context for one filesystem-query revision."

  alias MingaEditor.UI.Picker.FilesystemQuery

  @enforce_keys [:query]
  defstruct [:query]

  @type t :: %__MODULE__{query: FilesystemQuery.t()}

  @doc "Wraps a filesystem query for PickerState source ownership."
  @spec new(FilesystemQuery.t()) :: t()
  def new(%FilesystemQuery{} = query), do: %__MODULE__{query: query}
end
