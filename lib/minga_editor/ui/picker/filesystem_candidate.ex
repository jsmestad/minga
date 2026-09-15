defmodule MingaEditor.UI.Picker.FilesystemCandidate do
  @moduledoc """
  Captured identity for one shallow filesystem finder entry.

  The producing query and parent directory travel with the absolute entry path so stale entries
  cannot be selected after query or navigation replacement.
  """

  @enforce_keys [:query_identity, :parent_directory, :path, :kind]
  defstruct [:query_identity, :parent_directory, :path, :kind]

  @type kind :: :file | :directory
  @type t :: %__MODULE__{
          query_identity: reference(),
          parent_directory: String.t(),
          path: String.t(),
          kind: kind()
        }

  @doc "Builds one candidate from a direct-child listing."
  @spec new(reference(), String.t(), String.t(), kind()) :: t()
  def new(query_identity, parent_directory, path, kind)
      when is_reference(query_identity) and is_binary(parent_directory) and is_binary(path) and
             kind in [:file, :directory] do
    %__MODULE__{
      query_identity: query_identity,
      parent_directory: parent_directory,
      path: path,
      kind: kind
    }
  end

  @doc "Rebinds a cached direct child to a newer query over the same directory."
  @spec rebind(t(), reference()) :: t()
  def rebind(%__MODULE__{} = candidate, query_identity) when is_reference(query_identity) do
    %{candidate | query_identity: query_identity}
  end
end
