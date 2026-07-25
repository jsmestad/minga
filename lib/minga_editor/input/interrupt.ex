defmodule MingaEditor.Input.Interrupt do
  @moduledoc """
  Ctrl-G interrupt handler. First handler in the input stack.

  Cancels transient input, blurs focused owners without hiding durable
  surfaces, resets mode state, and derives the surviving keymap scope from
  the active window.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Input.CUA.TUISpaceLeader
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.WhichKey
  alias MingaEditor.VimState
  alias Minga.Mode

  # Ctrl-G sends codepoint 7 (BEL / ASCII control code for ^G).
  @ctrl_g 7

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, @ctrl_g, 0) do
    {:handled, interrupt(state)}
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  @doc "Resets transient editor state to a known-good baseline."
  @spec interrupt(EditorState.t()) :: EditorState.t()
  def interrupt(state) do
    {new_state, resets} = reset_to_known_good(state)
    log_resets(new_state, resets)
  end

  # ── Reset logic ──────────────────────────────────────────────────────────

  defp reset_to_known_good(state) do
    {state, resets} = {state, []}

    {state, resets} = maybe_dismiss_modal(state, resets)
    {state, resets} = maybe_clear_whichkey(state, resets)
    {state, resets} = maybe_reset_focus_owners(state, resets)
    {state, resets} = maybe_reset_mode(state, resets)
    {state, resets} = maybe_derive_scope(state, resets)
    {state, resets} = maybe_clear_agent_prefix(state, resets)
    {state, resets} = maybe_clear_status(state, resets)

    {state, resets}
  end

  defp maybe_derive_scope(%{workspace: %{keymap_scope: current_scope}} = state, resets) do
    scope = SessionState.scope_for_active_window(state.workspace)

    if current_scope == scope do
      {state, resets}
    else
      {%{state | workspace: SessionState.set_keymap_scope(state.workspace, scope)},
       ["scope #{current_scope} → #{scope}" | resets]}
    end
  end

  defp maybe_reset_focus_owners(state, resets) do
    new_state =
      state
      |> maybe_cancel_space_leader()
      |> maybe_blur_bottom_panel()
      |> maybe_blur_agent_prompt()
      |> maybe_unfocus_file_tree()
      |> maybe_clear_sidebar_focus()

    if new_state == state, do: {state, resets}, else: {new_state, ["focus owners reset" | resets]}
  end

  defp maybe_cancel_space_leader(
         %{shell_runtime: %{state: %TraditionalState{} = shell_state}} = state
       ) do
    if TraditionalState.space_leader_pending?(shell_state) or
         TraditionalState.space_leader_timer(shell_state) != nil,
       do: TUISpaceLeader.cancel(state),
       else: state
  end

  defp maybe_cancel_space_leader(state), do: state

  defp maybe_blur_bottom_panel(
         %{shell_runtime: %{state: %TraditionalState{bottom_panel: %{focused: true}}}} = state
       ),
       do: %{state | shell_runtime: Runtime.blur_bottom_panel(state.shell_runtime)}

  defp maybe_blur_bottom_panel(state), do: state

  defp maybe_blur_agent_prompt(
         %{workspace: %{agent_ui: %{panel: %{input_focused: true}}}} = state
       ) do
    Workflow.install_agent_ui(
      state,
      PromptBuffer.set_input_focused(state.workspace.agent_ui, false)
    )
  end

  defp maybe_blur_agent_prompt(state), do: state

  defp maybe_unfocus_file_tree(%{workspace: %{file_tree: %FileTreeState{} = file_tree}} = state) do
    new_file_tree =
      file_tree
      |> FileTreeState.hide_help()
      |> FileTreeState.cancel_editing()
      |> FileTreeState.accept_filter()
      |> FileTreeState.unfocus()

    if new_file_tree == file_tree,
      do: state,
      else: %{state | workspace: SessionState.set_file_tree(state.workspace, new_file_tree)}
  end

  defp maybe_clear_sidebar_focus(%EditorState{} = state) do
    table = state.extension_surfaces.sidebar_registry

    if SidebarWorkflow.active_id(state) != nil or Enum.any?(Sidebar.all(table), & &1.focused?),
      do: SidebarWorkflow.select(state, nil),
      else: state
  end

  defp maybe_reset_mode(%{workspace: %{editing: %{mode: mode}}} = state, resets)
       when mode != :normal do
    {%{state | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :normal)},
     ["mode #{mode} → :normal" | resets]}
  end

  defp maybe_reset_mode(%{workspace: %{editing: vim}} = state, resets) do
    fresh_state = Mode.initial_state()

    if mode_state_dirty?(vim.mode_state, fresh_state) do
      new_vim = VimState.set_mode_state(vim, fresh_state)

      {%{state | workspace: MingaEditor.Session.State.set_editing(state.workspace, new_vim)},
       ["mode state reset (pending sequence cleared)" | resets]}
    else
      {state, resets}
    end
  end

  defp mode_state_dirty?(%Minga.Mode.State{} = current, %Minga.Mode.State{} = fresh) do
    current.leader_node != fresh.leader_node or
      current.leader_keys != fresh.leader_keys or
      current.prefix_node != fresh.prefix_node or
      current.prefix_keys != fresh.prefix_keys or
      current.pending != fresh.pending or
      current.describe_key != fresh.describe_key or
      current.count != fresh.count or
      current.insert_changed != fresh.insert_changed
  end

  defp mode_state_dirty?(_current, _fresh), do: true

  defp maybe_dismiss_modal(state, resets) do
    if ModalOverlay.active?(state.shell_runtime.state.modal) do
      {ModalWorkflow.dismiss(state), ["modal dismissed" | resets]}
    else
      {state, resets}
    end
  end

  defp maybe_clear_whichkey(
         %{shell_runtime: %{state: %{whichkey: %WhichKey{node: nil, show: false}}}} = state,
         resets
       ),
       do: {state, resets}

  defp maybe_clear_whichkey(state, resets) do
    {WhichKeyWorkflow.dismiss(state), ["which-key dismissed" | resets]}
  end

  defp maybe_clear_agent_prefix(state, resets) do
    case state.workspace.agent_ui.view |> UIState.View.pending_prefix() do
      nil ->
        {state, resets}

      _prefix ->
        new_state =
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            UIState.clear_prefix(state.workspace.agent_ui)
          )

        {new_state, ["agent prefix cleared" | resets]}
    end
  end

  defp maybe_clear_status(
         %{
           shell_runtime: %{state: %{notice: %MingaEditor.Shell.Traditional.Notice{message: nil}}}
         } = state,
         resets
       ),
       do: {state, resets}

  defp maybe_clear_status(state, resets) do
    {NoticeWorkflow.dismiss(state), ["notice dismissed" | resets]}
  end

  # ── Logging ──────────────────────────────────────────────────────────────

  defp log_resets(state, []) do
    Minga.Log.info(:editor, "C-g: already in clean state")
    state
  end

  defp log_resets(state, resets) do
    detail = resets |> Enum.reverse() |> Enum.join(", ")
    Minga.Log.info(:editor, "C-g: #{detail}")
    state
  end
end
