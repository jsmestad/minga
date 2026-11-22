defmodule MingaEditor.Extension.GitStatus do
  @moduledoc """
  Enables the native Git Status sidebar for an extension.

  Minga owns the sidebar and its cached repository snapshot. Extensions own
  commit prompts and Git operations.
  """

  alias Minga.Extension.InvocationContext
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Shell.Traditional.SidebarWorkflow

  @typedoc "The displayed repository and last commit message, or why no target is available."
  @type commit_target :: SidebarWorkflow.commit_target()

  @doc "Registers the unique native surface. Call this from the extension's `init/1`."
  @spec register() :: :ok | {:error, term()}
  def register do
    case InvocationContext.current_source() do
      {:ok, {:extension, _name} = source} ->
        Sidebar.register_git_status(Sidebar.default_table(), source)

      _ ->
        {:error, :not_extension_callback}
    end
  end

  @doc "Opens, focuses, or closes Git Status. Does nothing when the surface is unavailable."
  @spec toggle(EditorAPI.state()) :: EditorAPI.state()
  defdelegate toggle(state), to: SidebarWorkflow, as: :toggle_git_status

  @doc """
  Shows Git Status and returns the exact displayed repository and last commit message.

  Returns `:not_git` outside a repository, or `:repo_unavailable` with a
  notice in the returned state when Git Status cannot provide a commit target.
  """
  @spec prepare_commit(EditorAPI.state()) :: {EditorAPI.state(), commit_target()}
  defdelegate prepare_commit(state), to: SidebarWorkflow, as: :prepare_git_commit
end
