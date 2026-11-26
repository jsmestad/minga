defmodule MingaEditor.Input.TasksDrawer do
  @moduledoc """
  Routes keys to the tasks drawer while it has the keyboard.

  Keys resolve through the `:tasks` keymap scope (`Minga.Keymap.Scope.Tasks`). The drawer runs ahead of the conversation's approval keys, so `y` answers the task the drawer selects, not whichever conversation is active. `SPC` (the leader), `:` (the command line) and chords pass through; any other key the drawer does not bind is dropped, so a letter meant for the drawer never edits the file above it.
  """

  @behaviour MingaEditor.Input.Handler

  alias Minga.Editing
  alias Minga.Keymap
  alias MingaEditor.Input
  alias MingaEditor.Shell.Traditional.TasksDrawerWorkflow
  alias MingaEditor.State, as: EditorState

  @passthrough_keys [?\s]

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%EditorState{} = state, cp, mods) do
    if TasksDrawerWorkflow.focused?(state) and not Input.key_sequence_pending?(state) and
         Editing.binding_state(state) in [:normal, :cua] do
      prefix = TasksDrawerWorkflow.awaited_key(state)
      state = if prefix, do: TasksDrawerWorkflow.await_key(state, nil), else: state
      state |> resolve(prefix, {cp, mods}) |> apply_binding(state, cp, mods)
    else
      {:passthrough, state}
    end
  end

  @spec resolve(
          EditorState.t(),
          Keymap.Bindings.node_t() | nil,
          {non_neg_integer(), non_neg_integer()}
        ) ::
          {:prefix, Keymap.Bindings.node_t()} | {:command, atom()} | :not_found
  defp resolve(state, nil, key) do
    Keymap.resolve_scoped_key(:tasks, Editing.binding_state(state), key,
      keymap_server: state.interaction.keymap_server
    )
  end

  defp resolve(_state, prefix, key), do: Keymap.Bindings.lookup(prefix, key)

  @spec apply_binding(term(), EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp apply_binding({:command, command}, state, _cp, _mods),
    do: {:handled, execute(state, command)}

  defp apply_binding({:prefix, node}, state, _cp, _mods),
    do: {:handled, TasksDrawerWorkflow.await_key(state, node)}

  # `:` opens the command line from Vim Normal; under CUA it would type, so the drawer keeps it.
  defp apply_binding(_unbound, state, ?:, 0) do
    if Editing.binding_state(state) == :normal, do: {:passthrough, state}, else: {:handled, state}
  end

  defp apply_binding(_unbound, state, cp, 0) when cp not in @passthrough_keys,
    do: {:handled, state}

  defp apply_binding(_unbound, state, _cp, _mods), do: {:passthrough, state}

  @spec execute(EditorState.t(), atom()) :: EditorState.t()
  defp execute(state, command) do
    case Atom.to_string(command) do
      "tasks_" <> _drawer -> TasksDrawerWorkflow.run(state, command)
      _other -> MingaEditor.Commands.execute(state, command)
    end
  end
end
