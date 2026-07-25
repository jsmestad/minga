defmodule MingaEditor.UI.Prompt.ProjectRemoveConfirm do
  @moduledoc """
  Prompt handler for confirming removal of a known project.
  """

  @behaviour MingaEditor.UI.Prompt.Handler

  alias Minga.Project
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec label() :: String.t()
  def label, do: "Remove project? (y/n): "

  @impl true
  @spec on_submit(String.t(), EditorState.t()) :: EditorState.t()
  def on_submit(text, state), do: confirm(text, state, project_path(nil, state))

  @impl true
  @spec on_submit(String.t(), EditorState.t(), map() | nil) :: EditorState.t()
  def on_submit(text, state, context), do: confirm(text, state, project_path(context, state))

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state),
    do: NoticeWorkflow.publish(state, "Project removal cancelled")

  @spec confirm(String.t(), EditorState.t(), String.t() | nil) :: EditorState.t()
  defp confirm(text, state, path) do
    answer = text |> String.trim() |> String.downcase()

    case {answer, path} do
      {answer, path} when answer in ["y", "yes"] and is_binary(path) ->
        Project.remove(path)
        NoticeWorkflow.publish(state, "Removed project: #{path}")

      {answer, _path} when answer in ["y", "yes"] ->
        NoticeWorkflow.publish(state, "No project selected")

      _ ->
        NoticeWorkflow.publish(state, "Project removal cancelled")
    end
  end

  @spec project_path(map() | nil, EditorState.t()) :: String.t() | nil
  defp project_path(%{path: path}, _state) when is_binary(path), do: path

  defp project_path(_context, %{
         shell_runtime: %{state: %{modal: {:prompt, %{prompt_ui: %{context: %{path: path}}}}}}
       })
       when is_binary(path),
       do: path

  defp project_path(_context, _state), do: nil
end
