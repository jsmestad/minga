defmodule MingaEditor.Shell.Traditional.SignatureHelpWorkflow do
  @moduledoc "Editor-state workflow for value-owned signature-help transitions."

  alias MingaEditor.HoverPopup
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.SignatureHelp
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.WhichKey

  @doc "Shows signature help unless a higher interactive surface owns input."
  @spec show(EditorState.t(), SignatureHelp.t()) :: EditorState.t()
  def show(
        %EditorState{shell_runtime: %Runtime{state: %ShellState{modal: modal}}} = state,
        %SignatureHelp{}
      )
      when modal != :none,
      do: state

  def show(
        %EditorState{
          shell_runtime: %Runtime{state: %ShellState{whichkey: %WhichKey{node: node}}}
        } = state,
        %SignatureHelp{}
      )
      when node != nil,
      do: state

  def show(
        %EditorState{
          shell_runtime: %Runtime{state: %ShellState{hover_popup: %HoverPopup{focused: true}}}
        } = state,
        %SignatureHelp{}
      ),
      do: state

  def show(
        %EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state,
        %SignatureHelp{} = signature_help
      ),
      do: update_shell_state(state, &ShellState.show_signature_help(&1, signature_help))

  def show(%EditorState{} = state, %SignatureHelp{}), do: state

  @doc "Cycles to the next signature overload."
  @spec next(EditorState.t()) :: EditorState.t()
  def next(%EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state),
    do: update_shell_state(state, &ShellState.next_signature_help/1)

  def next(%EditorState{} = state), do: state

  @doc "Cycles to the previous signature overload."
  @spec previous(EditorState.t()) :: EditorState.t()
  def previous(%EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state),
    do: update_shell_state(state, &ShellState.previous_signature_help/1)

  def previous(%EditorState{} = state), do: state

  @doc "Dismisses signature help."
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(%EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state),
    do: update_shell_state(state, &ShellState.dismiss_signature_help/1)

  def dismiss(%EditorState{} = state), do: state

  @spec update_shell_state(EditorState.t(), (MingaEditor.Shell.Traditional.State.t() ->
                                               MingaEditor.Shell.Traditional.State.t())) ::
          EditorState.t()
  defp update_shell_state(%EditorState{} = state, transition) when is_function(transition, 1) do
    shell_state = state.shell_runtime |> Runtime.state() |> transition.()
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end
end
