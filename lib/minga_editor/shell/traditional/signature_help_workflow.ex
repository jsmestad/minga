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
    do: EditorState.update_shell_state(state, &ShellState.show_signature_help(&1, signature_help))

  def show(state, _signature_help), do: state

  @doc "Cycles to the next signature overload."
  @spec next(EditorState.t()) :: EditorState.t()
  def next(%{shell_runtime: %{state: %ShellState{}}} = state),
    do: EditorState.update_shell_state(state, &ShellState.next_signature_help/1)

  def next(state), do: state

  @doc "Cycles to the previous signature overload."
  @spec previous(EditorState.t()) :: EditorState.t()
  def previous(%{shell_runtime: %{state: %ShellState{}}} = state),
    do: EditorState.update_shell_state(state, &ShellState.previous_signature_help/1)

  def previous(state), do: state

  @doc "Dismisses signature help."
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(%{shell_runtime: %{state: %ShellState{}}} = state),
    do: EditorState.update_shell_state(state, &ShellState.dismiss_signature_help/1)

  def dismiss(state), do: state
end
