defmodule MingaGitPorcelain.UI.Prompt.GitAmend do
  @moduledoc """
  Prompt handler for amending the most recent git commit.

  Opens a text input pre-filled with the last commit message. On submit,
  amends the previous commit with the new message via `Git.commit/3`
  with the `:amend` option.
  """

  @behaviour MingaEditor.UI.Prompt.Handler

  alias Minga.Git
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec label() :: String.t()
  def label, do: "Amend message: "

  @impl true
  @spec on_submit(String.t(), EditorState.t()) :: EditorState.t()
  def on_submit(text, state) do
    trimmed = String.trim(text)

    if trimmed == "" do
      EditorState.set_status(state, "Amend aborted: empty message")
    else
      do_amend(state, trimmed)
    end
  end

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: state

  @spec do_amend(EditorState.t(), String.t()) :: EditorState.t()
  defp do_amend(state, message) do
    case Git.root_for(Minga.Project.resolve_root()) do
      {:ok, git_root} ->
        case Git.commit(git_root, message, amend: true) do
          {:ok, hash} ->
            refresh_repo(git_root)
            EditorState.set_status(state, "Amended #{hash}")

          {:error, reason} ->
            EditorState.set_status(state, "Amend failed: #{reason}")
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
