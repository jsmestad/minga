defmodule MingaEditor.Shell.Traditional.HoverPopupWorkflow do
  @moduledoc "Editor-state workflow for value-owned hover popup transitions."

  alias MingaEditor.HoverPopup
  alias MingaEditor.Commands
  alias MingaEditor.LspActions
  alias MingaEditor.Shell.Traditional.ActMenuWorkflow
  alias MingaEditor.Shell.Traditional.CodeHoverWorkflow
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

  @doc "Moves keyboard selection among the currently offered documentation links."
  @spec select_link(EditorState.t(), :next | :previous) :: EditorState.t()
  def select_link(state, direction), do: update(state, &HoverPopup.select_link(&1, direction))

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

  @doc "Keeps the hover's captured Act source only until the Normal `g` prefix ends."
  @spec clear_finished_act_prefix(EditorState.t()) :: EditorState.t()
  def clear_finished_act_prefix(
        %{
          workspace: %{
            editing: %{mode: :normal, mode_state: %Minga.Mode.State{prefix_keys: ["g"]}}
          }
        } = state
      ),
      do: state

  def clear_finished_act_prefix(
        %{shell_runtime: %{state: %ShellState{hover_act_origin: origin}}} = state
      )
      when is_integer(origin),
      do: update_shell_state(state, &ShellState.clear_hover_act/1)

  def clear_finished_act_prefix(state), do: state

  @doc "Dismisses the popup and opens the target it offered."
  @spec activate_open(EditorState.t()) :: EditorState.t()
  def activate_open(
        %{
          shell_runtime: %{
            state: %ShellState{hover_popup: %HoverPopup{open_action: action} = popup}
          }
        } =
          state
      )
      when action != nil do
    next = dismiss(state)

    if CodeHoverWorkflow.source_live?(state, popup.code_source),
      do: run_open_action(next, action),
      else: next
  end

  def activate_open(state), do: state

  @doc "Applies only an action from the still-presented hover offer."
  @spec activate_offer(EditorState.t(), pos_integer(), :open | :actions | {:link, pos_integer()}) ::
          EditorState.t()
  def activate_offer(
        %{shell_runtime: %{state: %ShellState{hover_popup: %HoverPopup{offer_id: offer}}}} = state,
        offer,
        :open
      ),
      do: activate_open(state)

  def activate_offer(
        %{
          shell_runtime: %{
            state: %ShellState{hover_popup: %HoverPopup{offer_id: offer, code_source: source}}
          }
        } =
          state,
        offer,
        :actions
      )
      when source != nil,
      do: ActMenuWorkflow.open_hover(state, source)

  def activate_offer(
        %{shell_runtime: %{state: %ShellState{hover_popup: %HoverPopup{offer_id: offer} = popup}}} =
          state,
        offer,
        {:link, id}
      ) do
    with url when is_binary(url) <- HoverPopup.link_at(popup, id),
         :ok <- admit_link(state, popup, url) do
      launch_link(state, url)
    else
      _stale_or_unavailable -> state
    end
  end

  def activate_offer(state, _offer, _action), do: state

  @spec admit_link(EditorState.t(), HoverPopup.t(), String.t()) :: :ok | :stale
  defp admit_link(state, popup, url) do
    if CodeHoverWorkflow.source_live?(state, popup.code_source) and
         MingaAgent.Markdown.safe_url?(url) do
      :ok
    else
      :stale
    end
  end

  @spec launch_link(EditorState.t(), String.t()) :: EditorState.t()
  defp launch_link(state, url) do
    case Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn -> open_link(url) end) do
      {:ok, _worker} ->
        dismiss(state)

      {:error, _reason} ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Could not open link")
    end
  end

  @spec open_link(String.t()) :: :ok
  defp open_link(url) do
    case Minga.Platform.open_url(url) do
      :ok -> :ok
      {:error, reason} -> Minga.API.message("Could not open link: #{reason}")
    end
  end

  @spec run_open_action(EditorState.t(), HoverPopup.open_action()) :: EditorState.t()
  defp run_open_action(state, {:goto_location, uri, line, col}),
    do: LspActions.open_location(state, uri, line, col)

  defp run_open_action(state, {:open_session, session_id, tool_call_id}),
    do: Commands.Agent.open_session(state, session_id, tool_call_id)

  defp run_open_action(state, action) when is_atom(action) do
    case Commands.execute(state, action) do
      {next, _action} -> next
      next -> next
    end
  end

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
