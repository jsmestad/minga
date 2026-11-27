defmodule MingaEditor.FileTree.Delete do
  @moduledoc "Runs confirmed file-tree deletion outside the Editor and applies the result to the live workspace."

  @behaviour MingaEditor.Effect

  alias Minga.Core.FileIdentity
  alias Minga.Log
  alias Minga.Mode.DeleteConfirmState
  alias Minga.Platform
  alias Minga.Project.FileTree
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.Mutation
  alias MingaEditor.FocusOwner
  alias MingaEditor.Session.State, as: Workspace
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.Tab

  @enforce_keys [:confirmation, :root, :tab_id]
  defstruct [:confirmation, :root, :tab_id]

  @type t :: %__MODULE__{
          confirmation: DeleteConfirmState.t(),
          root: String.t() | nil,
          tab_id: Tab.id() | nil
        }

  @doc "Submits only the exact path and phase the user confirmed."
  @spec schedule(EditorState.t(), DeleteConfirmState.phase(), String.t()) :: EditorState.t()
  def schedule(state, phase, path) do
    case state.workspace.editing.mode_state do
      %DeleteConfirmState{phase: ^phase, path: ^path} = confirmation ->
        effect = %__MODULE__{
          confirmation: confirmation,
          root: tree_root(state),
          tab_id: tab_id(state)
        }

        admit(state, effect)

      _other ->
        state
    end
  end

  @spec admit(EditorState.t(), t()) :: EditorState.t()
  defp admit(state, effect) do
    case Mutation.schedule(state, effect) do
      {:ok, _id, _disposition} ->
        state

      {:error, reason} ->
        NoticeWorkflow.publish(state, "Delete not started: #{inspect(reason)}. Try again.")
    end
  end

  @impl true
  @spec run(t()) :: {:ok, :deleted} | {:error, term()}
  def run(%__MODULE__{confirmation: prompt}) do
    with :ok <- confirm_identity(prompt.path, prompt.identity) do
      delete(prompt.phase, prompt.path)
    end
  end

  @spec delete(DeleteConfirmState.phase(), String.t()) :: {:ok, :deleted} | {:error, term()}
  defp delete(:trash, path) do
    case Platform.trash(path) do
      :ok -> {:ok, :deleted}
      {:error, reason} -> {:error, {:trash_failed, reason}}
    end
  end

  defp delete(:permanent, path) do
    case Platform.permanent_delete(path) do
      :ok -> {:ok, :deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec confirm_identity(String.t(), FileIdentity.t()) :: :ok | {:error, term()}
  defp confirm_identity(path, expected) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} ->
        if FileIdentity.from_stat(stat) == expected, do: :ok, else: {:error, :target_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{value: {:completed, :deleted}, request: %Request{effect: effect}} = result
      ) do
    %{phase: phase, name: name} = effect.confirmation
    action = if phase == :trash, do: "Moved to trash", else: "Permanently deleted"
    Log.info(:editor, "[file-tree] #{action}: #{name}")
    {Freshness.request_refresh(state, 0), result}
  end

  def apply(
        state,
        %Outcome{
          value: {:failed, {:trash_failed, reason}},
          request: %Request{effect: effect}
        } = result
      ) do
    Log.warning(:editor, "[file-tree] Trash failed for #{effect.confirmation.path}: #{reason}")

    if fallback_context?(state, effect) do
      prompt = DeleteConfirmState.to_permanent(effect.confirmation)
      workspace = Workspace.transition_mode(state.workspace, :delete_confirm, prompt)
      {%{state | workspace: workspace}, result}
    else
      message = "Could not trash #{effect.confirmation.name}. No permanent delete was attempted."
      {NoticeWorkflow.publish(state, message), result}
    end
  end

  def apply(state, %Outcome{value: {status, reason}, request: %Request{effect: effect}} = result)
      when status in [:failed, :canceled] do
    message = "Delete did not complete for #{effect.confirmation.name}: #{reason_text(reason)}"
    Log.warning(:editor, "[file-tree] #{message}")
    {NoticeWorkflow.publish(Freshness.request_refresh(state, 0), message), result}
  end

  def apply(state, %Outcome{} = result), do: {state, result}

  @spec reason_text(term()) :: String.t()
  defp reason_text(:target_changed), do: "the entry changed since confirmation"
  defp reason_text(:enoent), do: "the entry no longer exists"
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _result}}), do: status in [:failed, :canceled]
  def render?(%Outcome{}), do: false

  @spec fallback_context?(EditorState.t(), t()) :: boolean()
  defp fallback_context?(
         %{
           workspace: %{editing: %{mode: :normal}, keymap_scope: :file_tree},
           shell_runtime: %Runtime{state: %ShellState{modal: modal}}
         } = state,
         effect
       ) do
    tree = state.workspace.file_tree

    FileTreeState.focused?(tree) and tree.interaction == :browse and
      not ModalOverlay.active?(modal) and
      FocusOwner.derive(state).surface == :file_tree and
      tree_root(state) == effect.root and tab_id(state) == effect.tab_id
  end

  defp fallback_context?(_state, _effect), do: false

  @spec tree_root(EditorState.t()) :: String.t() | nil
  defp tree_root(state) do
    case FileTreeState.tree(state.workspace.file_tree) do
      %FileTree{root: root} -> root
      nil -> nil
    end
  end

  @spec tab_id(EditorState.t()) :: Tab.id() | nil
  defp tab_id(state) do
    case Runtime.active_tab(state.shell_runtime) do
      %{id: id} -> id
      nil -> nil
    end
  end
end
