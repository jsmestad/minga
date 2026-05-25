defmodule MingaGitPorcelain.UI.Prompt.GitCommit do
  @moduledoc """
  Prompt handler for committing from the TUI git status panel.

  Opens a minibuffer prompt with "Commit message: ". On submit, commits
  the staged changes and refreshes the git status panel.
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
    message = String.trim(text)

    if message == "" do
      EditorState.set_status(state, "Commit cancelled: empty message")
    else
      commit_and_refresh(state, message)
    end
  end

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: state

  @spec commit_and_refresh(EditorState.t(), String.t()) :: EditorState.t()
  defp commit_and_refresh(state, message) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        case Git.commit(git_root, message) do
          {:ok, short_hash} ->
            refresh_repo(git_root)
            EditorState.set_status(state, "Committed #{short_hash}")

          {:error, reason} ->
            EditorState.set_status(state, "Commit failed: #{reason}")
        end
    end
  end

  @spec resolve_git_root() :: String.t() | nil
  defp resolve_git_root do
    root = Minga.Project.resolve_root()

    case Git.root_for(root) do
      {:ok, git_root} -> git_root
      :not_git -> nil
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
