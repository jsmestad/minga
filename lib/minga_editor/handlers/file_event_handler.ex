defmodule MingaEditor.Handlers.FileEventHandler do
  @moduledoc """
  Pure handler for file and git status events.

  Extracts the `{:minga_event, :git_status_changed, ...}`,
  `{:minga_event, :buffer_saved, ...}`, and `{:git_remote_result, ...}`
  clauses from the Editor GenServer into pure `{state, [effect]}`
  functions.
  """

  alias MingaEditor.State, as: EditorState
  alias Minga.Project.FileTree

  @typedoc "Effects that the file event handler may return."
  @type file_effect ::
          :render
          | {:render, pos_integer()}
          | {:log_message, String.t()}
          | {:refresh_tree_git_status}
          | {:request_code_lens}
          | {:request_inlay_hints}
          | {:save_session_deferred}
          | {:handle_git_remote_result, reference(), term()}

  @doc """
  Dispatches a file/git event to the appropriate handler.

  Returns `{state, effects}` where effects encode all side-effectful
  operations.
  """
  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [file_effect()]}

  def handle(state, {:minga_event, :git_status_changed, event}) do
    handle_git_status_changed(state, event)
  end

  def handle(state, {:minga_event, :buffer_saved, %Minga.Events.BufferEvent{}}) do
    handle_buffer_saved(state)
  end

  def handle(state, {:git_remote_result, ref, result}) when is_reference(ref) do
    {state, [{:handle_git_remote_result, ref, result}]}
  end

  def handle(state, _msg) do
    {state, []}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec handle_git_status_changed(EditorState.t(), Minga.Events.GitStatusEvent.t()) ::
          {EditorState.t(), [file_effect()]}
  defp handle_git_status_changed(state, %Minga.Events.GitStatusEvent{
         entries: entries,
         branch: branch,
         ahead: ahead,
         behind: behind
       }) do
    if EditorState.git_status_panel(state) != nil do
      git_status_data = %{
        repo_state: :normal,
        branch: branch || "",
        ahead: ahead,
        behind: behind,
        entries: entries
      }

      new_state = EditorState.set_git_status_panel(state, git_status_data)
      {new_state, [{:render, 16}]}
    else
      {state, []}
    end
  end

  @spec handle_buffer_saved(EditorState.t()) :: {EditorState.t(), [file_effect()]}
  defp handle_buffer_saved(state) do
    # Refresh file tree git status
    new_state = refresh_tree_git_status(state)

    effects = [
      {:request_code_lens},
      {:request_inlay_hints}
    ]

    # Save session on file save (skip in headless)
    effects =
      if state.backend != :headless do
        effects ++ [{:save_session_deferred}]
      else
        effects
      end

    {new_state, effects}
  end

  # Refreshes the file tree's git status annotations.
  @spec refresh_tree_git_status(EditorState.t()) :: EditorState.t()
  defp refresh_tree_git_status(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  defp refresh_tree_git_status(%{workspace: %{file_tree: %{tree: tree}}} = state) do
    updated_tree = FileTree.refresh_git_status(tree)
    put_in(state.workspace.file_tree.tree, updated_tree)
  end
end
