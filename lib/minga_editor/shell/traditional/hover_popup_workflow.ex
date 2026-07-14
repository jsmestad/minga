defmodule MingaEditor.Shell.Traditional.HoverPopupWorkflow do
  @moduledoc "Editor-state workflow for value-owned hover popup transitions."

  alias MingaEditor.HoverPopup
  alias MingaEditor.Shell.Traditional.SignatureHelpWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState

  @doc "Shows newly produced hover content unless a higher interactive surface owns input."
  @spec show(EditorState.t(), HoverPopup.t()) :: EditorState.t()
  def show(%{shell_runtime: %{state: %{modal: modal}}} = state, _popup) when modal != :none,
    do: state

  def show(%{shell_runtime: %{state: %{whichkey: %{node: node}}}} = state, _popup)
      when node != nil,
      do: state

  def show(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        %HoverPopup{focused: true} = popup
      ) do
    state
    |> SignatureHelpWorkflow.dismiss()
    |> update_shell_state(&ShellState.show_hover_popup(&1, popup))
  end

  def show(%{shell_runtime: %{state: %ShellState{}}} = state, popup),
    do: update_shell_state(state, &ShellState.show_hover_popup(&1, popup))

  def show(state, _popup), do: state

  @doc "Focuses the active hover popup and suppresses lower signature help."
  @spec focus(EditorState.t()) :: EditorState.t()
  def focus(%{shell_runtime: %{state: %ShellState{}}} = state) do
    state
    |> SignatureHelpWorkflow.dismiss()
    |> update(&HoverPopup.focus/1)
  end

  def focus(state), do: state

  @doc "Scrolls the active hover popup down."
  @spec scroll_down(EditorState.t()) :: EditorState.t()
  def scroll_down(state), do: update(state, &HoverPopup.scroll_down/1)

  @doc "Scrolls the active hover popup up."
  @spec scroll_up(EditorState.t()) :: EditorState.t()
  def scroll_up(state), do: update(state, &HoverPopup.scroll_up/1)

  @doc "Toggles expanded hover content."
  @spec toggle_expand(EditorState.t()) :: EditorState.t()
  def toggle_expand(state), do: update(state, &HoverPopup.toggle_expand/1)

  @doc "Dismisses the active hover popup."
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(%{shell_runtime: %{state: %ShellState{}}} = state),
    do: update_shell_state(state, &ShellState.dismiss_hover_popup/1)

  def dismiss(state), do: state

  @spec update(EditorState.t(), (HoverPopup.t() -> HoverPopup.t())) :: EditorState.t()
  defp update(
         %{shell_runtime: %{state: %{hover_popup: %MingaEditor.HoverPopup{} = popup}}} = state,
         transition
       ) do
    updated_popup = transition.(popup)
    update_shell_state(state, &ShellState.show_hover_popup(&1, updated_popup))
  end

  defp update(state, _transition), do: state

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
