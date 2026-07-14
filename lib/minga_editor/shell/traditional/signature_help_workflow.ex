defmodule MingaEditor.Shell.Traditional.SignatureHelpWorkflow do
  @moduledoc "Editor-state workflow for value-owned signature-help transitions."

  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.SignatureHelp
  alias MingaEditor.State, as: EditorState

  @doc "Shows signature help unless a higher interactive surface owns input."
  @spec show(EditorState.t(), SignatureHelp.t()) :: EditorState.t()
  def show(%{shell_runtime: %{state: %{modal: modal}}} = state, _signature_help)
      when modal != :none,
      do: state

  def show(%{shell_runtime: %{state: %{whichkey: %{node: node}}}} = state, _signature_help)
      when node != nil,
      do: state

  def show(%{shell_runtime: %{state: %{hover_popup: %{focused: true}}}} = state, _signature_help),
    do: state

  def show(%{shell_runtime: %{state: %ShellState{}}} = state, signature_help),
    do: update_shell_state(state, &ShellState.show_signature_help(&1, signature_help))

  def show(state, _signature_help), do: state

  @doc "Cycles to the next signature overload."
  @spec next(EditorState.t()) :: EditorState.t()
  def next(%{shell_runtime: %{state: %ShellState{}}} = state),
    do: update_shell_state(state, &ShellState.next_signature_help/1)

  def next(state), do: state

  @doc "Cycles to the previous signature overload."
  @spec previous(EditorState.t()) :: EditorState.t()
  def previous(%{shell_runtime: %{state: %ShellState{}}} = state),
    do: update_shell_state(state, &ShellState.previous_signature_help/1)

  def previous(state), do: state

  @doc "Dismisses signature help."
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(%{shell_runtime: %{state: %ShellState{}}} = state),
    do: update_shell_state(state, &ShellState.dismiss_signature_help/1)

  def dismiss(state), do: state

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
