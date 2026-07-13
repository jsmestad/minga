defmodule MingaEditor.GitRepositoryIdentity do
  @moduledoc """
  Resolved identity for a git repository and the project path that selected it.

  The repository root is the mutation scheduler resource. The source root keeps
  git-panel paths correct when the active project is nested inside a repository.
  """

  @enforce_keys [:git_root, :source_root]
  defstruct [:git_root, :source_root]

  @type t :: %__MODULE__{git_root: String.t(), source_root: String.t()}

  @doc "Builds a normalized repository identity."
  @spec new(String.t(), String.t()) :: t()
  def new(git_root, source_root) when is_binary(git_root) and is_binary(source_root) do
    %__MODULE__{git_root: Path.expand(git_root), source_root: Path.expand(source_root)}
  end
end
