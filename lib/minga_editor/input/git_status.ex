defmodule MingaEditor.Input.GitStatus do
  @moduledoc "Routes focused Git status keys to cached navigation or the shared status actions."
  @behaviour MingaEditor.Input.Handler

  alias Minga.Editing
  alias Minga.Keymap
  alias MingaEditor.Commands
  alias MingaEditor.GitStatus.Panel
  alias MingaEditor.GitStatus.TUIState
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Input
  alias MingaEditor.Shell.Traditional.GitToastWorkflow
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{workspace: %{keymap_scope: :git_status}} = state, cp, mods) do
    if Input.key_sequence_pending?(state) do
      {:passthrough, state}
    else
      tui = tui_state(state)
      key = {cp, mods}
      apply_binding(state, tui, resolve_binding(state, tui.pending_prefix, key))
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @spec resolve_binding(EditorState.t(), Keymap.Bindings.node_t() | nil, {integer(), integer()}) ::
          {:prefix, Keymap.Bindings.node_t()} | {:command, atom()} | :not_found
  defp resolve_binding(state, nil, key) do
    Keymap.resolve_scoped_key(:git_status, Editing.binding_state(state), key,
      keymap_server: state.interaction.keymap_server
    )
  end

  defp resolve_binding(state, prefix, key) do
    case Keymap.Bindings.lookup(prefix, key) do
      :not_found -> resolve_binding(state, nil, key)
      matched -> matched
    end
  end

  @spec apply_binding(
          EditorState.t(),
          TUIState.t(),
          {:prefix, Keymap.Bindings.node_t()} | {:command, atom()} | :not_found
        ) :: MingaEditor.Input.Handler.result()
  defp apply_binding(state, tui, {:prefix, node}) do
    {:handled, SidebarWorkflow.replace_git_status_tui(state, TUIState.set_prefix(tui, node))}
  end

  defp apply_binding(state, tui, binding) do
    state =
      if tui.pending_prefix do
        SidebarWorkflow.replace_git_status_tui(state, TUIState.set_prefix(tui, nil))
      else
        state
      end

    case binding do
      {:command, command} -> {:handled, execute(state, command)}
      :not_found -> {:passthrough, state}
    end
  end

  @spec execute(EditorState.t(), atom()) :: EditorState.t()
  defp execute(state, command) when command in [:git_status_next, :move_down],
    do: navigate(state, &TUIState.next/2)

  defp execute(state, command) when command in [:git_status_prev, :move_up],
    do: navigate(state, fn tui, _ -> TUIState.prev(tui) end)

  defp execute(state, :git_status_next_section), do: navigate(state, &TUIState.next_section/2)
  defp execute(state, :git_status_prev_section), do: navigate(state, &TUIState.prev_section/2)

  defp execute(state, :git_status_toggle_section),
    do: navigate(state, &TUIState.toggle_current_section/2)

  defp execute(state, :git_status_close) do
    case tui_state(state) do
      %TUIState{discard_confirmation: nil} -> SidebarWorkflow.close_git_status(state)
      %TUIState{} -> execute(state, :git_status_cancel_discard)
    end
  end

  defp execute(state, :git_status_stage_all), do: dispatch_panel_action(state, :git_stage_all)

  defp execute(state, :git_status_unstage_all), do: dispatch_panel_action(state, :git_unstage_all)

  defp execute(state, :git_status_push), do: dispatch_panel_action(state, :git_push)
  defp execute(state, :git_status_pull), do: dispatch_panel_action(state, :git_pull)
  defp execute(state, :git_status_fetch), do: dispatch_panel_action(state, :git_fetch)
  defp execute(state, :git_status_retry), do: GitToastWorkflow.retry_current(state)
  defp execute(state, :git_commit_open), do: Commands.execute(state, :git_commit_open)

  defp execute(state, :git_generate_commit_message),
    do: Commands.execute(state, :git_generate_commit_message)

  defp execute(state, :git_status_cancel_discard) do
    navigate(state, fn tui, _ -> TUIState.clear_discard_confirmation(tui) end)
  end

  defp execute(state, :git_status_confirm_discard) do
    case SidebarWorkflow.git_status_tui_state(state) do
      %TUIState{discard_confirmation: {panel_id, path, section}} ->
        state
        |> execute(:git_status_cancel_discard)
        |> GuiActionHandler.dispatch({:git_discard_file, panel_id, path, section})

      _none ->
        state
    end
  end

  defp execute(state, operation) do
    case SidebarWorkflow.git_status_panel(state) do
      %Panel{id: panel_id, entries: entries, git_root: root} when is_binary(root) ->
        case TUIState.selected_file(tui_state(state), entries) do
          nil -> state
          entry -> perform_file_action(state, operation, panel_id, entry)
        end

      _missing ->
        state
    end
  end

  @spec dispatch_panel_action(
          EditorState.t(),
          :git_stage_all | :git_unstage_all | :git_push | :git_pull | :git_fetch
        ) :: EditorState.t()
  defp dispatch_panel_action(state, operation) do
    case SidebarWorkflow.git_status_panel(state) do
      %Panel{id: panel_id} -> GuiActionHandler.dispatch(state, {operation, panel_id})
      nil -> state
    end
  end

  @spec perform_file_action(EditorState.t(), atom(), Panel.id(), Minga.Git.StatusEntry.t()) ::
          EditorState.t()
  defp perform_file_action(state, :git_status_open_file, panel_id, entry) do
    GuiActionHandler.dispatch(state, {:git_open_file, panel_id, entry.path, Panel.section(entry)})
  end

  defp perform_file_action(state, :git_status_open_diff, panel_id, entry) do
    GuiActionHandler.dispatch(state, {:git_open_diff, panel_id, entry.path, Panel.section(entry)})
  end

  defp perform_file_action(state, :git_status_stage, panel_id, %{staged: staged?} = entry) do
    action = if staged?, do: :git_unstage_file, else: :git_stage_file
    GuiActionHandler.dispatch(state, {action, panel_id, entry.path, Panel.section(entry)})
  end

  defp perform_file_action(state, :git_status_unstage, panel_id, entry) do
    GuiActionHandler.dispatch(
      state,
      {:git_unstage_file, panel_id, entry.path, Panel.section(entry)}
    )
  end

  defp perform_file_action(state, :git_status_discard, panel_id, %{staged: false} = entry) do
    state
    |> navigate(fn tui, _ -> TUIState.request_discard(tui, panel_id, entry) end)
    |> NoticeWorkflow.publish(
      "Discard changes to #{entry.path}? Press y to confirm or n to cancel."
    )
  end

  defp perform_file_action(state, _operation, _panel_id, _entry), do: state

  @spec navigate(EditorState.t(), (TUIState.t(), [Minga.Git.StatusEntry.t()] -> TUIState.t())) ::
          EditorState.t()
  defp navigate(state, move) do
    case SidebarWorkflow.git_status_panel(state) do
      %{entries: entries} ->
        next = state |> tui_state() |> move.(entries) |> TUIState.clamp_cursor(entries)
        SidebarWorkflow.replace_git_status_tui(state, next)

      nil ->
        state
    end
  end

  @spec tui_state(EditorState.t()) :: TUIState.t()
  defp tui_state(state), do: SidebarWorkflow.git_status_tui_state(state) || TUIState.new()
end
