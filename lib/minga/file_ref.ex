defmodule Minga.FileRef do
  @moduledoc """
  Stable identity for a logical file path.

  File tabs should compare the file they represent, not their display label. The label is usually a basename and can collide across directories, while a file ref stores the normalized path used by buffer processes.
  """

  @type t :: %__MODULE__{path: String.t()}

  @enforce_keys [:path]
  defstruct [:path]

  @doc "Builds a file reference from a filesystem path."
  @spec new(String.t()) :: t()
  def new(path) when is_binary(path) do
    %__MODULE__{path: Path.expand(path)}
  end

  @doc "Returns true when two file references identify the same logical file."
  @spec same?(t(), t()) :: boolean()
  def same?(%__MODULE__{path: path}, %__MODULE__{path: path}), do: true
  def same?(%__MODULE__{}, %__MODULE__{}), do: false
end
