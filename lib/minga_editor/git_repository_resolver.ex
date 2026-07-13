defmodule MingaEditor.GitRepositoryResolver do
  @moduledoc """
  Resolves the current project to its actual repository identity.

  Resolution may call the project service and `git rev-parse`, so callers must
  invoke it from supervised slow-effect work rather than the Editor process.
  """

  alias MingaEditor.GitRepositoryIdentity

  @typedoc "Typed resolver input accepted by a resolver implementation."
  @type input :: term()

  @callback resolve(input()) :: {:ok, GitRepositoryIdentity.t()} | :not_git | {:error, term()}

  @doc "Resolves the current project root through the configured git backend."
  @spec resolve(:current_project | String.t()) ::
          {:ok, GitRepositoryIdentity.t()} | :not_git | {:error, term()}
  def resolve(:current_project) do
    resolve(Minga.Project.resolve_root())
  end

  def resolve(source_root) when is_binary(source_root) do
    case Minga.Git.root_for(source_root) do
      {:ok, git_root} -> {:ok, GitRepositoryIdentity.new(git_root, source_root)}
      :not_git -> :not_git
    end
  end
end
