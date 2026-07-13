defmodule Minga.Test.GitRepositoryResolver do
  @moduledoc "Deterministic data-driven repository resolver for async git effect tests."

  @behaviour MingaEditor.GitRepositoryResolver

  alias MingaEditor.GitRepositoryIdentity

  @type input ::
          {:return, String.t(), String.t()}
          | {:block, pid(), term(), String.t(), String.t()}
          | :not_git

  @impl true
  @spec resolve(input()) :: {:ok, GitRepositoryIdentity.t()} | :not_git
  def resolve({:return, git_root, source_root}) do
    {:ok, GitRepositoryIdentity.new(git_root, source_root)}
  end

  def resolve({:block, test_pid, tag, git_root, source_root}) do
    send(test_pid, {:git_resolver_blocked, tag, self()})

    receive do
      {:release_git_resolver, ^tag} ->
        {:ok, GitRepositoryIdentity.new(git_root, source_root)}
    end
  end

  def resolve(:not_git), do: :not_git
end
