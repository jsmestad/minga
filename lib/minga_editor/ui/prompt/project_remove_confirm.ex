defmodule MingaEditor.UI.Prompt.ProjectRemoveConfirm do
  @moduledoc """
  Prompt handler for confirming removal of a known project.
  """

  @behaviour MingaEditor.UI.Prompt.Handler

  alias Minga.Project
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec label() :: String.t()
  def label, do: "Remove project? (y/n): "

  @impl true
  @spec on_submit(String.t(), EditorState.t()) :: EditorState.t()
  def on_submit(text, state) do
    answer = text |> String.trim() |> String.downcase()

    case {answer, project_path(state)} do
      {answer, path} when answer in ["y", "yes"] and is_binary(path) ->
        Project.remove(path)
        EditorState.set_status(state, "Removed project: #{path}")

      {answer, _path} when answer in ["y", "yes"] ->
        EditorState.set_status(state, "No project selected")

      _ ->
        EditorState.set_status(state, "Project removal cancelled")
    end
  end

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: EditorState.set_status(state, "Project removal cancelled")

  @spec project_path(EditorState.t()) :: String.t() | nil
  defp project_path(%{shell_state: %{modal: {:prompt, %{prompt_ui: %{context: %{path: path}}}}}})
       when is_binary(path),
       do: path

  defp project_path(_state), do: nil
end
