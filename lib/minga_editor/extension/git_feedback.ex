defmodule MingaEditor.Extension.GitFeedback do
  @moduledoc "Shows remote Git outcomes in the Git status surface and minibuffer. A retry proposal retains the exact repository and extension activation."

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.RepositoryJob
  alias MingaEditor.Shell.Traditional.GitToastWorkflow

  @doc "Starts a new remote operation, clearing the previous feedback."
  @spec progress(EditorAPI.state(), String.t()) :: EditorAPI.state()
  def progress(state, message) do
    state |> GitToastWorkflow.dismiss() |> EditorAPI.notice(message)
  end

  @doc "Shows an outcome. An optional source-owned job is offered as Pull and Retry."
  @spec publish(EditorAPI.state(), String.t(), :success | :error, RepositoryJob.t() | nil) ::
          EditorAPI.state()
  def publish(state, message, level, retry \\ nil)

  def publish(state, message, level, nil) when level in [:success, :error] do
    state |> EditorAPI.notice(message) |> GitToastWorkflow.publish(message, level)
  end

  def publish(state, message, :error, retry) do
    retry = RepositoryJob.remote_retry(retry)
    state |> EditorAPI.notice(message) |> GitToastWorkflow.publish(message, :error, retry)
  end
end
