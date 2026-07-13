defmodule MingaEditor.Shell.Traditional.WhichKeyWorkflow do
  @moduledoc "Effectful timer workflow for the pure which-key lifecycle owner."

  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
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
      |> EditorState.update_shell_state(&ShellState.suppress_lower_transients/1)
      |> EditorState.update_shell_state(&ShellState.begin_whichkey(&1, node, prefix_keys))

    schedule(state)
  end

  @doc "Advances a leader prefix unless an exclusive modal owns input."
  @spec progress(EditorState.t(), Minga.Keymap.Bindings.node_t(), [String.t()]) :: EditorState.t()
  def progress(%{shell_runtime: %{state: %{modal: modal}}} = state, _node, _prefix_keys)
      when modal != :none,
      do: state

  def progress(state, node, prefix_keys) do
    cancel_timer(state.shell_runtime.state.whichkey.timer)

    state =
      state
      |> EditorState.update_shell_state(&ShellState.suppress_lower_transients/1)
      |> EditorState.update_shell_state(&ShellState.progress_whichkey(&1, node, prefix_keys))

    schedule(state)
  end

  @doc "Dismisses which-key and cancels its current timer best-effort."
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(state) do
    cancel_timer(state.shell_runtime.state.whichkey.timer)
    EditorState.update_shell_state(state, &ShellState.dismiss_whichkey/1)
  end

  @doc "Reveals only a matching active which-key generation."
  @spec reveal(EditorState.t(), WhichKey.generation()) :: EditorState.t()
  def reveal(
        %{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state,
        generation
      ),
      do: EditorState.update_shell_state(state, &ShellState.reveal_whichkey(&1, generation))

  def reveal(state, _generation), do: state

  @doc "Moves which-key to the next page."
  @spec next_page(EditorState.t()) :: EditorState.t()
  def next_page(state),
    do: EditorState.update_shell_state(state, &ShellState.next_whichkey_page/1)

  @doc "Moves which-key to the previous page."
  @spec previous_page(EditorState.t()) :: EditorState.t()
  def previous_page(state),
    do: EditorState.update_shell_state(state, &ShellState.previous_whichkey_page/1)

  @spec schedule(EditorState.t()) :: EditorState.t()
  defp schedule(state) do
    generation = state.shell_runtime.state.whichkey.generation

    case Application.get_env(:minga, :whichkey_timeout_ms, @default_timeout_ms) do
      :infinity ->
        state

      timeout when is_integer(timeout) and timeout >= 0 ->
        timer = Process.send_after(self(), {:whichkey_reveal, generation}, timeout)

        EditorState.update_shell_state(
          state,
          &ShellState.record_whichkey_timer(&1, generation, timer)
        )

      invalid ->
        raise ArgumentError,
              "whichkey_timeout_ms must be a non-negative integer or :infinity, got: #{inspect(invalid)}"
    end
  end

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end
end
