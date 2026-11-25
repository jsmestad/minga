defmodule MingaEditor.Shell.Traditional.WhichKeyWorkflow do
  @moduledoc "Effectful timer workflow for the pure which-key lifecycle owner."

  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.WhichKey

  @default_timeout_ms 300

  @doc "Begins a delayed generation unless an exclusive modal owns input."
  @spec begin(EditorState.t(), Minga.Keymap.Bindings.node_t(), [String.t()]) :: EditorState.t()
  def begin(%{shell_runtime: %{state: %{modal: modal}}} = state, _node, _prefix_keys)
      when modal != :none,
      do: state

  def begin(state, node, prefix_keys) do
    cancel_timer(state.shell_runtime.state.whichkey.timer)

    state =
      state
      |> update_shell_state(&ShellState.suppress_lower_transients/1)
      |> update_shell_state(&ShellState.begin_whichkey(&1, node, prefix_keys))

    schedule(state)
  end

  @doc "Advances a leader prefix unless an exclusive modal owns input. `label` names a group whose node has no description."
  @spec progress(EditorState.t(), Minga.Keymap.Bindings.node_t(), [String.t()], String.t() | nil) ::
          EditorState.t()
  def progress(state, node, prefix_keys, label \\ nil)

  def progress(%{shell_runtime: %{state: %{modal: modal}}} = state, _node, _prefix_keys, _label)
      when modal != :none,
      do: state

  def progress(state, node, prefix_keys, label) do
    cancel_timer(state.shell_runtime.state.whichkey.timer)

    state =
      state
      |> update_shell_state(&ShellState.suppress_lower_transients/1)
      |> update_shell_state(&ShellState.progress_whichkey(&1, node, prefix_keys, label))

    schedule(state)
  end

  @doc "Shows the pending which-key generation now, without waiting for the pause (the mode pill opens it by click)."
  @spec reveal_now(EditorState.t()) :: EditorState.t()
  def reveal_now(state), do: reveal(state, state.shell_runtime.state.whichkey.generation)

  @doc """
  Opens which-key on the keys of a prompt or picker scope, at once. It opens over the prompt or picker, so unlike a leader sequence it does not yield to the modal that owns input.
  """
  @spec open_scope(EditorState.t(), Minga.Keymap.Bindings.node_t(), String.t()) :: EditorState.t()
  def open_scope(state, node, name) do
    cancel_timer(state.shell_runtime.state.whichkey.timer)
    update_shell_state(state, &ShellState.open_whichkey_scope(&1, node, name))
  end

  @doc """
  Dismisses a leader which-key under a modal that takes input. A prompt or picker's own keys, opened over that modal by the mode pill, stay while the same kind of modal stays open (`next_tag`): results loading or the selection moving is not a reason to close them, but a picker that hands over to a prompt is.
  """
  @spec dismiss_under_modal(EditorState.t(), atom()) :: EditorState.t()
  def dismiss_under_modal(
        %{shell_runtime: %{state: %{whichkey: %WhichKey{owner: :scope}, modal: modal}}} = state,
        next_tag
      ) do
    if ModalOverlay.tag(modal) == next_tag, do: state, else: dismiss(state)
  end

  def dismiss_under_modal(state, _next_tag), do: dismiss(state)

  @doc "Dismisses a prompt or picker's own keys when that modal closes; a leader which-key is left alone."
  @spec dismiss_scope(EditorState.t()) :: EditorState.t()
  def dismiss_scope(%{shell_runtime: %{state: %{whichkey: %WhichKey{owner: :scope}}}} = state),
    do: dismiss(state)

  def dismiss_scope(state), do: state

  @doc "Dismisses which-key and cancels its current timer best-effort."
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(state) do
    cancel_timer(state.shell_runtime.state.whichkey.timer)
    update_shell_state(state, &ShellState.dismiss_whichkey/1)
  end

  @doc "Reveals only a matching active which-key generation."
  @spec reveal(EditorState.t(), WhichKey.generation()) :: EditorState.t()
  def reveal(
        %{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state,
        generation
      ),
      do: update_shell_state(state, &ShellState.reveal_whichkey(&1, generation))

  def reveal(state, _generation), do: state

  @spec schedule(EditorState.t()) :: EditorState.t()
  defp schedule(state) do
    generation = state.shell_runtime.state.whichkey.generation

    case Application.get_env(:minga, :whichkey_timeout_ms, @default_timeout_ms) do
      :infinity ->
        state

      timeout when is_integer(timeout) and timeout >= 0 ->
        timer = Process.send_after(self(), {:whichkey_reveal, generation}, timeout)

        update_shell_state(
          state,
          &ShellState.record_whichkey_timer(&1, generation, timer)
        )

      invalid ->
        raise ArgumentError,
              "whichkey_timeout_ms must be a non-negative integer or :infinity, got: #{inspect(invalid)}"
    end
  end

  @spec cancel_timer(reference() | nil) :: :ok
  # Timer cancellation stays visible in this independently owned workflow.
  # ex_dna:disable-for-next-line
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  @spec update_shell_state(EditorState.t(), (MingaEditor.Shell.Traditional.State.t() ->
                                               MingaEditor.Shell.Traditional.State.t())) ::
          EditorState.t()
  # This workflow retains its explicit Traditional-state installation boundary.
  # ex_dna:disable-for-next-line
  defp update_shell_state(%EditorState{} = state, transition) when is_function(transition, 1) do
    shell_state = state.shell_runtime |> MingaEditor.Shell.Runtime.state() |> transition.()

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end
end
