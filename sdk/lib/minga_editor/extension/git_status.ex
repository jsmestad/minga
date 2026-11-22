defmodule MingaEditor.Extension.GitStatus do
  @moduledoc """
  Enables the native Git Status sidebar for an extension.

  Minga owns the sidebar and its cached repository snapshot. Extensions own
  commit prompts and Git operations. The SDK declares the API for compilation;
  the editor provides the runtime.
  """

  alias MingaEditor.Extension.EditorAPI

  @typedoc "The displayed repository and last commit message, or why no target is available."
  @type commit_target :: {:ok, String.t(), String.t() | nil} | :not_git | :repo_unavailable

  @doc "Registers the unique native surface. Call this from the extension's `init/1`."
  @spec register() :: :ok | {:error, term()}
  def register, do: raise("minga_sdk is compile-time only")

  @doc "Opens, focuses, or closes Git Status. Does nothing when the surface is unavailable."
  @spec toggle(EditorAPI.state()) :: EditorAPI.state()
  def toggle(_state), do: raise("minga_sdk is compile-time only")

  @doc """
  Shows Git Status and returns the exact displayed repository and last commit message.

  Returns `:not_git` outside a repository, or `:repo_unavailable` with a
  notice in the returned state when Git Status cannot provide a commit target.
  """
  @spec prepare_commit(EditorAPI.state()) :: {EditorAPI.state(), commit_target()}
  def prepare_commit(_state), do: raise("minga_sdk is compile-time only")
end
