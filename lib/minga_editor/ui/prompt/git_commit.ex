defmodule MingaEditor.UI.Prompt.GitCommit do
  @moduledoc """
  Prompt handler for creating a git commit.

  Opens a text input for the commit message. On submit, commits all
  staged changes with the entered message and refreshes the git repo.
  """

  @behaviour MingaEditor.UI.Prompt.Handler

  alias Minga.Git
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec label() :: String.t()
  def label, do: "Commit message: "

  @impl true
  @spec on_submit(String.t(), EditorState.t()) :: EditorState.t()
  def on_submit(text, state) do
    trimmed = String.trim(text)

    if trimmed == "" do
      EditorState.set_status(state, "Commit aborted: empty message")
    else
      do_commit(state, trimmed)
    end
  end

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: state

  @spec do_commit(EditorState.t(), String.t()) :: EditorState.t()
  defp do_commit(state, message) do
    case Git.root_for(Minga.Project.resolve_root()) do
      {:ok, git_root} ->
        case Git.commit(git_root, message) do
          {:ok, hash} ->
            refresh_repo(git_root)
            EditorState.set_status(state, "Committed #{hash}")

          {:error, reason} ->
            EditorState.set_status(state, "Commit failed: #{reason}")
        end

      :not_git ->
        EditorState.set_status(state, "Not in a git repository")
    end
  end

  @spec refresh_repo(String.t()) :: :ok
  defp refresh_repo(git_root) do
    case Git.lookup_repo(git_root) do
      nil -> :ok
      pid -> Git.refresh_repo(pid)
    end
  end
end
