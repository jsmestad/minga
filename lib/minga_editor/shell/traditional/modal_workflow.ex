defmodule MingaEditor.Shell.Traditional.ModalWorkflow do
  @moduledoc "Editor-state workflow around the pure `ModalOverlay` value owner."

  alias MingaEditor.CompletionTrigger
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.Tab

  @doc "Opens an exact modal value, preserving conflict stickiness and suppressing lower transients."
  @spec open(EditorState.t(), ModalOverlay.active()) :: EditorState.t()
  def open(
        %EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state,
        modal
      ) do
    previous = state.shell_runtime.state.modal
    next = ModalOverlay.open(previous, modal)
    variant = ModalOverlay.tag(modal)

    if next == previous and ModalOverlay.match(previous, :conflict) and variant != :conflict do
      Minga.Log.info(
        :editor,
        "ModalOverlay.open(#{inspect(variant)}) suppressed: conflict prompt is active"
      )

      state
    else
      state
      |> suppress_lower_surfaces()
      |> update_shell_state(&ShellState.open_modal(&1, modal))
    end
  end

  def open(%EditorState{} = state, _modal), do: state

  @doc "Transitions to an exact modal value unconditionally and suppresses lower transients."
  @spec transition(EditorState.t(), ModalOverlay.active()) :: EditorState.t()
  def transition(
        %EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state,
        modal
      ) do
    state
    |> suppress_lower_surfaces()
    |> update_shell_state(&ShellState.transition_modal(&1, modal))
  end

  def transition(%EditorState{} = state, _modal), do: state

  @doc "Closes a completed modal."
  @spec close(EditorState.t()) :: EditorState.t()
  def close(%EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state),
    do: update_shell_state(state, &ShellState.close_modal/1)

  def close(%EditorState{} = state), do: state

  @doc "Dismisses a canceled modal and cancels only its local completion timers."
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(%EditorState{shell_runtime: %Runtime{state: %ShellState{modal: modal}}} = state) do
    cancel_completion_timers(modal)
    update_shell_state(state, &ShellState.dismiss_modal/1)
  end

  def dismiss(%EditorState{} = state), do: state

  @doc "Returns the active inner completion value."
  @spec completion(EditorState.t() | Input.t()) :: Minga.Editing.Completion.t() | nil
  def completion(%EditorState{shell_runtime: %Runtime{state: %ShellState{} = shell_state}}),
    do: shell_state |> ShellState.modal() |> ModalOverlay.completion()

  def completion(%Input{shell_state: %ShellState{} = shell_state}),
    do: shell_state |> ShellState.modal() |> ModalOverlay.completion()

  def completion(%EditorState{}), do: nil
  def completion(%Input{}), do: nil

  @doc "Returns the active completion trigger or a fresh trigger."
  @spec completion_trigger(EditorState.t() | Input.t()) :: MingaEditor.CompletionTrigger.t()
  def completion_trigger(%EditorState{
        shell_runtime: %Runtime{state: %ShellState{} = shell_state}
      }),
      do: shell_state |> ShellState.modal() |> ModalOverlay.completion_trigger()

  def completion_trigger(%Input{shell_state: %ShellState{} = shell_state}),
    do: shell_state |> ShellState.modal() |> ModalOverlay.completion_trigger()

  def completion_trigger(%EditorState{}), do: MingaEditor.CompletionTrigger.new()
  def completion_trigger(%Input{}), do: MingaEditor.CompletionTrigger.new()

  @doc "Updates the active completion value."
  @spec update_completion(EditorState.t(), (Minga.Editing.Completion.t() ->
                                              Minga.Editing.Completion.t())) ::
          EditorState.t()
  def update_completion(
        %EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state,
        update
      ),
      do: update_shell_state(state, &ShellState.update_modal_completion(&1, update))

  def update_completion(%EditorState{} = state, _update), do: state

  @doc "Records completion-trigger lifecycle with current tab context."
  @spec put_completion_trigger(EditorState.t(), MingaEditor.CompletionTrigger.t()) ::
          EditorState.t()
  def put_completion_trigger(
        %EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state,
        trigger
      ) do
    active_tab_id = active_tab_id(state)

    update_shell_state(
      state,
      &ShellState.put_modal_completion_trigger(&1, trigger, active_tab_id)
    )
  end

  def put_completion_trigger(%EditorState{} = state, _trigger), do: state

  @doc "Returns the active command-completion payload."
  @spec command_completion(EditorState.t() | Input.t()) ::
          MingaEditor.State.ModalOverlay.CommandCompletion.t() | nil
  def command_completion(%EditorState{
        shell_runtime: %Runtime{state: %ShellState{} = shell_state}
      }),
      do: shell_state |> ShellState.modal() |> ModalOverlay.command_completion()

  def command_completion(%Input{shell_state: %ShellState{} = shell_state}),
    do: shell_state |> ShellState.modal() |> ModalOverlay.command_completion()

  def command_completion(%EditorState{}), do: nil
  def command_completion(%Input{}), do: nil

  @doc "Dismisses completion owned by a different active tab."
  @spec dismiss_if_stale(EditorState.t()) :: EditorState.t()
  def dismiss_if_stale(%EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state) do
    active_tab_id = active_tab_id(state)

    update_shell_state(
      state,
      &ShellState.dismiss_stale_modal_completion(&1, active_tab_id)
    )
  end

  def dismiss_if_stale(%EditorState{} = state), do: state

  @spec suppress_lower_surfaces(EditorState.t()) :: EditorState.t()
  defp suppress_lower_surfaces(state) do
    state
    |> WhichKeyWorkflow.dismiss()
    |> update_shell_state(&ShellState.suppress_lower_transients/1)
  end

  @spec cancel_completion_timers(ModalOverlay.t()) :: :ok
  defp cancel_completion_timers(modal) do
    case ModalOverlay.completion(modal) do
      %{resolve_timer: timer} when is_reference(timer) -> Process.cancel_timer(timer)
      _completion -> :ok
    end

    _trigger = modal |> ModalOverlay.completion_trigger() |> CompletionTrigger.dismiss()
    :ok
  end

  @spec active_tab_id(EditorState.t()) :: Tab.id() | nil
  defp active_tab_id(%EditorState{shell_runtime: %Runtime{} = runtime}) do
    case Runtime.active_tab(runtime) do
      %Tab{id: id} -> id
      nil -> nil
    end
  end

  @spec update_shell_state(EditorState.t(), (MingaEditor.Shell.Traditional.State.t() ->
                                               MingaEditor.Shell.Traditional.State.t())) ::
          EditorState.t()
  defp update_shell_state(%EditorState{} = state, transition) when is_function(transition, 1) do
    shell_state = state.shell_runtime |> MingaEditor.Shell.Runtime.state() |> transition.()

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end
end
