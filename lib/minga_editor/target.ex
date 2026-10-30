defmodule MingaEditor.Target do
  @moduledoc """
  Resolves frontend identities against the current editor snapshot without effects.

  Resolution never changes selection, consults a buffer process, or reads the
  filesystem. Only resident, currently offered items can be activated.
  """

  alias Minga.Editing.Completion
  alias Minga.Project.FileTree
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.FileTree.Row
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Window

  @enforce_keys [:surface, :intent, :generation, :item_id]
  defstruct [:surface, :intent, :generation, :item_id]

  @type t :: %__MODULE__{
          surface: surface(),
          intent: atom(),
          generation: non_neg_integer(),
          item_id: binary()
        }

  @type surface :: :completion | :picker | :file_tree | :command_completion | :timeline
  @type target ::
          {:tab, Tab.id()}
          | {:window, Window.id(), non_neg_integer()}
          | t()
          | {:timeline_entry, non_neg_integer(), binary()}
  @type reason :: :not_found | :stale_generation | :target_mismatch
  @type resolved ::
          {:tab, Tab.t()}
          | {:window, Window.t()}
          | {:completion, Completion.t()}
          | {:picker_item, non_neg_integer(), non_neg_integer()}
          | {:picker_action, non_neg_integer(), non_neg_integer()}
          | {:file_tree, FileTree.t(), FileTree.entry() | nil}
          | {:command_completion, String.t()}
          | {:timeline_entry, String.t(), EditTimeline.Entry.t()}

  @spec resolve(EditorState.t(), target()) :: {:ok, resolved()} | {:error, reason()}
  def resolve(state, {:tab, id}) do
    case state.shell_runtime.state do
      %{tab_bar: %TabBar{} = tab_bar} ->
        case TabBar.get(tab_bar, id) do
          %Tab{} = tab -> {:ok, {:tab, tab}}
          nil -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def resolve(state, {:window, id, generation}) do
    case Map.get(state.workspace.windows.map, id) do
      nil ->
        {:error, :not_found}

      %Window{accessibility_generation: current} when current != generation ->
        {:error, :stale_generation}

      %Window{content: {:buffer, buffer}}
      when id == state.workspace.windows.active and
             buffer != state.workspace.buffers.active ->
        {:error, :target_mismatch}

      %Window{} = window ->
        {:ok, {:window, window}}
    end
  end

  def resolve(state, %__MODULE__{surface: :completion, generation: generation, item_id: id}) do
    with %Completion{} = completion <- ModalWorkflow.completion(state),
         :ok <- generation(ModalWorkflow.completion_generation(state), generation) do
      case Completion.select_wire_id(completion, id) do
        {:ok, selected} -> {:ok, {:completion, selected}}
        :stale -> {:error, :not_found}
      end
    else
      nil -> missing_modal(state)
      {:error, _} = error -> error
    end
  end

  def resolve(state, %__MODULE__{surface: :picker, generation: generation, item_id: <<id::32>>}) do
    case state.shell_runtime.state do
      %{modal: {:picker, %{picker_ui: %{activation_offer: offer}}}} ->
        with :ok <- generation(offer.generation, generation) do
          resolve_picker_item(state, offer.items, offer.actions, generation, id)
        end

      _ ->
        missing_modal(state)
    end
  end

  def resolve(state, %__MODULE__{surface: :file_tree, generation: generation, item_id: id}) do
    file_tree = state.workspace.file_tree

    case FileTreeState.tree(file_tree) do
      %FileTree{} = tree ->
        with :ok <- generation(FileTreeState.presentation_generation(file_tree), generation) do
          resolve_tree_entry(tree, id)
        end

      nil ->
        {:error, :not_found}
    end
  end

  def resolve(state, %__MODULE__{
        surface: :command_completion,
        generation: requested_generation,
        item_id: id
      }) do
    case {state.workspace.editing.mode, ModalWorkflow.command_completion(state)} do
      {:command, %{generation: current, candidates: candidates, filter_text: input}} ->
        with :ok <- generation(current, requested_generation),
             true <- input == state.workspace.editing.mode_state.input do
          resolve_command_candidate(candidates, id)
        else
          false -> {:error, :stale_generation}
          {:error, _} = error -> error
        end

      {:command, nil} ->
        {:error, :not_found}

      _ ->
        {:error, :target_mismatch}
    end
  end

  def resolve(state, %__MODULE__{surface: :timeline, generation: generation, item_id: id}),
    do: resolve(state, {:timeline_entry, generation, id})

  def resolve(state, {:timeline_entry, generation, id}) when is_binary(id) do
    timeline = state.workspace.agent_ui.view.edit_timeline

    with :ok <- generation(timeline.generation, generation) do
      found = Enum.find_value(timeline.entries, &find_timeline_entry(&1, id))

      if found, do: {:ok, found}, else: {:error, :not_found}
    end
  end

  def resolve(_state, _target), do: {:error, :target_mismatch}

  @spec generation(non_neg_integer(), non_neg_integer()) :: :ok | {:error, reason()}
  defp generation(current, requested) when current == requested and requested != 0, do: :ok
  defp generation(_current, _requested), do: {:error, :stale_generation}

  @spec resolve_picker_item(
          EditorState.t(),
          [tuple()],
          [tuple()],
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, resolved()} | {:error, reason()}
  defp resolve_picker_item(state, items, actions, generation, id) do
    case List.keyfind(items, id, 0) do
      nil -> resolve_picker_action(state, actions, generation, id)
      {_id, _index, item} -> resolve_picker_reference(state, item, {:picker_item, generation, id})
    end
  end

  @spec resolve_picker_action(EditorState.t(), [tuple()], non_neg_integer(), non_neg_integer()) ::
          {:ok, resolved()} | {:error, reason()}
  defp resolve_picker_action(state, actions, generation, id) do
    case List.keyfind(actions, id, 0) do
      nil ->
        {:error, :not_found}

      {_id, _action, item} ->
        resolve_picker_reference(state, item, {:picker_action, generation, id})
    end
  end

  @spec resolve_picker_reference(EditorState.t(), MingaEditor.UI.Picker.Item.t(), resolved()) ::
          {:ok, resolved()} | {:error, reason()}
  defp resolve_picker_reference(state, %{id: {:buffer, pid}}, resolved) do
    if Enum.member?(state.workspace.buffers.list, pid),
      do: {:ok, resolved},
      else: {:error, :not_found}
  end

  defp resolve_picker_reference(_state, _item, resolved), do: {:ok, resolved}

  @spec resolve_command_candidate([MingaEditor.MinibufferData.candidate()], binary()) ::
          {:ok, resolved()} | {:error, reason()}
  defp resolve_command_candidate(candidates, id) do
    case Enum.find(candidates, &(&1.label == id)) do
      nil -> {:error, :not_found}
      candidate -> {:ok, {:command_completion, candidate.label}}
    end
  end

  @spec find_timeline_entry({String.t(), [EditTimeline.Entry.t()]}, binary()) ::
          resolved() | nil
  defp find_timeline_entry({path, entries}, id) do
    case Enum.find(entries, &(EditTimeline.entry_id(path, &1) == id)) do
      nil -> nil
      entry -> {:timeline_entry, path, entry}
    end
  end

  @spec resolve_tree_entry(FileTree.t(), binary()) :: {:ok, resolved()} | {:error, reason()}
  defp resolve_tree_entry(tree, ""), do: {:ok, {:file_tree, tree, nil}}

  defp resolve_tree_entry(%FileTree{entries: entries} = tree, id) when is_list(entries) do
    case Enum.find(entries, &(Row.id_for(&1) == id)) do
      nil -> {:error, :not_found}
      entry -> {:ok, {:file_tree, tree, entry}}
    end
  end

  defp resolve_tree_entry(_tree, _id), do: {:error, :not_found}

  @spec missing_modal(EditorState.t()) :: {:error, reason()}
  defp missing_modal(state) do
    case state.shell_runtime.state do
      %{modal: :none} -> {:error, :not_found}
      %{modal: nil} -> {:error, :not_found}
      _ -> {:error, :target_mismatch}
    end
  end
end
