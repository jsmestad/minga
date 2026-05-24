defmodule MingaEditor.Handlers.GuiActionHandler do
  @moduledoc """
  Handler for GUI frontend semantic actions (SwiftUI chrome commands).

  Each action maps to existing editor operations. The `dispatch/2` entry
  point replaces the old `handle_gui_action/2` clauses from the Editor
  GenServer, converting SwiftUI chrome events into state transitions.

  Unlike the other handler modules that return `{state, [effect]}`, this
  handler returns `state` directly because GUI actions apply their side
  effects inline (renders, status updates, etc.).
  """

  alias Minga.Buffer
  alias Minga.Clipboard
  alias Minga.Editing.Completion
  alias Minga.FileWatcher
  alias Minga.Git
  alias Minga.LSP.Supervisor, as: LspSupervisor
  alias Minga.LSP.SyncServer, as: LspSyncServer

  alias MingaEditor.BottomPanel
  alias MingaEditor.Commands
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.HighlightSync
  alias MingaEditor.Layout
  alias MingaEditor.LspActions
  alias MingaEditor.Input.Observatory
  alias MingaEditor.MinibufferData
  alias MingaEditor.PickerUI
  alias MingaEditor.Renderer
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Search, as: SearchData
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows

  alias MingaAgent.Session, as: AgentSession

  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Startup

  alias Minga.Project.FileTree

  @typedoc "Editor state (re-exported for brevity)."
  @type state :: EditorState.t()

  # ── Public entry point ───────────────────────────────────────────────

  @doc """
  Dispatches a GUI action to the appropriate handler clause.

  Returns the updated editor state. Unrecognized actions are logged and
  the state is returned unchanged.
  """
  @spec dispatch(state(), Protocol.GUI.gui_action()) :: state()
  def dispatch(state, action) do
    dispatch_action(state, action)
  end

  # ── Internal dispatch clauses ────────────────────────────────────────

  @spec dispatch_action(state(), Protocol.GUI.gui_action()) :: state()

  defp dispatch_action(state, :system_will_sleep) do
    Minga.Log.info(:editor, "System will sleep")
    state
  end

  defp dispatch_action(state, :system_did_wake) do
    Minga.Log.info(:editor, "System did wake; refreshing files, LSP, and git")
    FileWatcher.check_all()
    refresh_current_git_repo()
    LspSupervisor.restart_all_clients()
    LspSyncServer.resync_buffers(buffers_for_lsp_resync(state))

    state
    |> EditorState.invalidate_all_windows()
    |> Layout.invalidate()
    |> Renderer.render_or_async()
  end

  defp dispatch_action(state, {:power_thermal_state, low_power?, thermal_state}) do
    Minga.Log.info(
      :editor,
      "Power/thermal state: low_power=#{low_power?}, thermal=#{inspect(thermal_state)}"
    )

    state = EditorState.set_resource_pressure(state, low_power?, thermal_state)

    Minga.Events.broadcast(
      :power_thermal_state_changed,
      %Minga.Events.PowerThermalStateEvent{
        low_power?: low_power?,
        thermal_state: thermal_state
      },
      EditorState.events_registry(state)
    )

    state
  end

  defp dispatch_action(state, :config_query) do
    MingaEditor.push_full_config_state(state)
    state
  end

  defp dispatch_action(state, {:config_update, name, value}) do
    if MingaEditor.Frontend.Protocol.GUI.settings_option?(name) do
      case Minga.Config.Options.set(EditorState.options_server(state), name, value) do
        {:ok, persisted_value} ->
          Minga.Config.Options.mark_explicit(EditorState.options_server(state), name)
          Minga.Config.Writer.persist(name, persisted_value)

          state
          |> MingaEditor.apply_runtime_config_option(name, persisted_value)
          |> MingaEditor.push_config_state_entry(name, persisted_value)

        {:error, reason} ->
          Minga.Log.warning(:config, "Ignored GUI config update for #{inspect(name)}: #{reason}")
          state
      end
    else
      Minga.Log.warning(
        :config,
        "Ignored GUI config update outside settings panel for #{inspect(name)}"
      )

      state
    end
  end

  defp dispatch_action(state, {:notification_dismiss, id}) do
    EditorState.dismiss_notification(state, id)
  end

  defp dispatch_action(state, {:notification_action, notification_id, action_id}) do
    case EditorState.notification_action(state, notification_id, action_id) do
      %{dispatch: {:command, command}} ->
        state
        |> EditorState.dismiss_notification(notification_id)
        |> Commands.execute(command)
        |> normalize_command_result()

      %{dispatch: {:event, event, payload}} ->
        Minga.Events.broadcast(event, payload, EditorState.events_registry(state))
        state

      _ ->
        state
    end
  end

  @min_font_size 8
  @max_font_size 72

  defp dispatch_action(state, {:font_size_adjust, direction}) do
    options_server = EditorState.options_server(state)
    config_size = Minga.Config.Options.get(options_server, :font_size)

    new_size =
      case direction do
        :increase -> min((state.font_size_override || config_size) + 1, @max_font_size)
        :decrease -> max((state.font_size_override || config_size) - 1, @min_font_size)
        :reset -> nil
      end

    state = %{state | font_size_override: new_size}
    Startup.send_font_config(state)
    state
  end

  defp dispatch_action(%{shell_state: shell_state} = state, {:observatory_inspect, pid_string}) do
    if Map.has_key?(shell_state, :observatory_inspection) do
      Observatory.inspect_process(state, pid_string)
    else
      state
    end
  end

  defp dispatch_action(state, {:timeline_navigate, index}) do
    MingaEditor.Commands.EditTimeline.navigate_to_index(state, index)
  end

  defp dispatch_action(state, {:extension_panel_action, ext_name, action_name, context}) do
    route_panel_action_to_extension(ext_name, action_name, context)
    state
  end

  defp dispatch_action(%{shell: MingaEditor.Shell.Board} = state, action) do
    {shell_state, workspace} =
      MingaEditor.Shell.Board.handle_gui_action(state.shell_state, state.workspace, action)

    state = %{state | shell_state: shell_state, workspace: workspace}

    # After Board zoom into an agent card, atomically activate the
    # agent view (session, scope, window content, prompt focus).
    # The Board handler can't do this because it only has
    # (shell_state, workspace), not the full EditorState.
    case action do
      {:board_select_card, card_id} ->
        card = Map.get(shell_state.cards, card_id)

        {new_board, state} =
          MingaEditor.Shell.Board.SessionLifecycle.ensure_session(state.shell_state, card, state)

        state = EditorState.update_shell_state(state, fn _ -> new_board end)
        card = new_board.cards[card_id]
        MingaEditor.AgentActivation.activate_for_card(state, card)

      _ ->
        state
    end
  end

  defp dispatch_action(state, {:select_tab, id}) do
    EditorState.switch_tab(state, id)
  end

  defp dispatch_action(state, {:tab_copy_path, id}) do
    copy_tab_path(state, id)
  end

  defp dispatch_action(state, {:tab_reorder, id, new_index}) do
    reorder_tab(state, id, new_index)
  end

  defp dispatch_action(state, {:tab_pin, id}) do
    update_tab_bar(state, &TabBar.pin_tab(&1, id))
  end

  defp dispatch_action(state, {:tab_unpin, id}) do
    update_tab_bar(state, &TabBar.unpin_tab(&1, id))
  end

  defp dispatch_action(state, {:tab_move_left, id}) do
    update_tab_bar(state, &TabBar.move_tab_left(&1, id))
  end

  defp dispatch_action(state, {:tab_move_right, id}) do
    update_tab_bar(state, &TabBar.move_tab_right(&1, id))
  end

  defp dispatch_action(state, :hover_open_action) do
    accept_hover_open_action(state)
  end

  defp dispatch_action(state, {:close_tab, id}) do
    # Delegate to the shell: Traditional switches to the target tab when
    # needed; Board and tab-bar-less Traditional return unchanged.
    {shell_state, workspace} =
      state.shell.handle_gui_action(state.shell_state, state.workspace, {:close_tab, id})

    state = %{state | shell_state: shell_state, workspace: workspace}

    # Only close the buffer when the shell has a tab bar.
    # EditorState.active_tab/1 returns nil when there are no tabs.
    if EditorState.active_tab(state) do
      Commands.BufferManagement.execute(state, :force_quit)
    else
      state
    end
  end

  defp dispatch_action(state, {:file_tree_click, index}) do
    gui_tree_action(state, index, :click)
  end

  defp dispatch_action(state, {:file_tree_toggle, index}) do
    gui_tree_action(state, index, :toggle)
  end

  defp dispatch_action(state, {:file_tree_open_in_split, index}) do
    open_file_tree_entry_in_split(state, index)
  end

  defp dispatch_action(state, {:file_tree_new_file, index}) do
    state = move_tree_cursor(state, index)
    Commands.FileTree.new_file(state)
  end

  defp dispatch_action(state, {:file_tree_new_folder, index}) do
    state = move_tree_cursor(state, index)
    Commands.FileTree.new_folder(state)
  end

  defp dispatch_action(state, {:file_tree_edit_confirm, text}) do
    case state.workspace.file_tree.editing do
      nil ->
        state

      %{} ->
        ft = FileTreeState.update_editing_text(state.workspace.file_tree, text)

        state =
          EditorState.set_file_tree(state, ft)

        Commands.FileTree.confirm_editing(state)
    end
  end

  defp dispatch_action(state, :file_tree_edit_cancel) do
    Commands.FileTree.cancel_editing(state)
  end

  defp dispatch_action(state, {:file_tree_delete, index}) do
    state = move_tree_cursor(state, index)
    Commands.FileTree.delete(state)
  end

  defp dispatch_action(state, {:file_tree_rename, index}) do
    state = move_tree_cursor(state, index)
    Commands.FileTree.rename(state)
  end

  defp dispatch_action(state, {:file_tree_duplicate, index}) do
    state = move_tree_cursor(state, index)
    Commands.FileTree.duplicate(state)
  end

  defp dispatch_action(state, {:file_tree_move, source_index, target_dir_index}) do
    Commands.FileTree.move(state, source_index, target_dir_index)
  end

  defp dispatch_action(state, {:file_tree_drop, intent}) do
    Commands.FileTree.drop(state, intent)
  end

  defp dispatch_action(state, :file_tree_collapse_all) do
    Commands.FileTree.collapse_all(state)
  end

  defp dispatch_action(state, :file_tree_refresh) do
    Commands.FileTree.refresh(state)
  end

  defp dispatch_action(state, {:completion_select, index}) do
    case MingaEditor.State.ModalOverlay.completion(state) do
      %Completion{} = comp ->
        accept_visible_completion(state, comp, index)

      nil ->
        state
    end
  end

  defp dispatch_action(state, {:breadcrumb_click, _segment_index}) do
    # Breadcrumb navigation is a follow-up feature.
    state
  end

  defp dispatch_action(state, {:toggle_panel, 0}) do
    Commands.FileTree.toggle(state)
  end

  defp dispatch_action(state, {:toggle_panel, 1}) do
    EditorState.set_bottom_panel(state, BottomPanel.toggle(EditorState.bottom_panel(state)))
  end

  defp dispatch_action(state, {:toggle_panel, 2}) do
    Commands.Git.execute(state, :git_status_toggle)
  end

  defp dispatch_action(state, {:toggle_panel, 3}) do
    Commands.Agent.toggle_agent_split(state)
  end

  defp dispatch_action(state, {:toggle_panel, 4}) do
    state
    |> Commands.execute(:toggle_beam_observatory)
    |> normalize_command_result()
  end

  defp dispatch_action(state, {:toggle_panel, _panel}) do
    state
  end

  defp dispatch_action(state, :new_tab) do
    Commands.BufferManagement.execute(state, :new_buffer)
  end

  defp dispatch_action(state, {:panel_switch_tab, tab_index}) do
    EditorState.set_bottom_panel(
      state,
      BottomPanel.switch_tab(EditorState.bottom_panel(state), tab_index)
    )
  end

  defp dispatch_action(state, :panel_dismiss) do
    EditorState.set_bottom_panel(state, BottomPanel.dismiss(EditorState.bottom_panel(state)))
  end

  defp dispatch_action(state, {:panel_resize, height_percent}) do
    EditorState.set_bottom_panel(
      state,
      BottomPanel.resize(EditorState.bottom_panel(state), height_percent)
    )
  end

  defp dispatch_action(state, {:open_file, path}) do
    if File.dir?(path) do
      open_dropped_directory(state, path)
    else
      BufferRegistry.open_file_by_path(state, path)
    end
  end

  defp dispatch_action(state, {:tool_install, name_str}) do
    name = String.to_existing_atom(name_str)

    case Minga.Tool.Manager.install(name) do
      :ok -> EditorState.set_status(state, "Installing #{name_str}...")
      {:error, reason} -> EditorState.set_status(state, "Cannot install #{name_str}: #{reason}")
    end
  rescue
    ArgumentError -> EditorState.set_status(state, "Unknown tool: #{name_str}")
  end

  defp dispatch_action(state, {:tool_uninstall, name_str}) do
    name = String.to_existing_atom(name_str)

    case Minga.Tool.Manager.uninstall(name) do
      :ok -> EditorState.set_status(state, "Uninstalled #{name_str}")
      {:error, reason} -> EditorState.set_status(state, "Cannot uninstall #{name_str}: #{reason}")
    end
  rescue
    ArgumentError -> EditorState.set_status(state, "Unknown tool: #{name_str}")
  end

  defp dispatch_action(state, {:tool_update, name_str}) do
    name = String.to_existing_atom(name_str)

    case Minga.Tool.Manager.update(name) do
      :ok -> EditorState.set_status(state, "Updating #{name_str}...")
      {:error, reason} -> EditorState.set_status(state, "Cannot update #{name_str}: #{reason}")
    end
  rescue
    ArgumentError -> EditorState.set_status(state, "Unknown tool: #{name_str}")
  end

  defp dispatch_action(state, :tool_dismiss) do
    # The tool manager panel is closed; no state change needed since
    # visibility is driven by the BEAM's render cycle
    state
  end

  defp dispatch_action(state, {:agent_tool_toggle, message_index}) do
    session = AgentAccess.session(state)

    if session do
      try do
        AgentSession.toggle_tool_collapse(session, message_index)
      catch
        :exit, _ -> :ok
      end
    end

    state
  end

  defp dispatch_action(state, {:minibuffer_select, index}) do
    case state.workspace.editing do
      %{mode: :command, mode_state: ms} ->
        {candidates, _total} = MinibufferData.complete_ex_command(ms.input)
        clamped = MinibufferData.clamp_index(index, length(candidates))

        case Enum.at(candidates, clamped) do
          nil ->
            state

          %{label: label} ->
            new_ms = %{ms | input: label, candidate_index: 0}
            set_vim_mode_state(state, new_ms)
        end

      _ ->
        state
    end
  end

  defp dispatch_action(state, {:execute_command, name_str}) do
    command = String.to_existing_atom(name_str)

    # Discard any follow-up action (dot_repeat, replay_macro): GUI chrome
    # buttons are not vim editing operations and don't participate in the
    # action pipeline.
    state
    |> Commands.execute(command)
    |> normalize_command_result()
  rescue
    ArgumentError ->
      Minga.Log.warning(:editor, "[execute_command] unrecognized command: #{name_str}")
      state
  end

  defp dispatch_action(state, {:git_stage_file, path}) do
    git_action(
      state,
      fn git_root -> Minga.Git.stage(git_root, git_relative_path(git_root, path)) end,
      "Staged #{path}"
    )
  end

  defp dispatch_action(state, {:git_unstage_file, path}) do
    git_action(
      state,
      fn git_root -> Minga.Git.unstage(git_root, git_relative_path(git_root, path)) end,
      "Unstaged #{path}"
    )
  end

  defp dispatch_action(state, {:git_discard_file, path}) do
    git_action(
      state,
      fn git_root -> Minga.Git.discard(git_root, git_relative_path(git_root, path)) end,
      "Discarded #{path}"
    )
  end

  defp dispatch_action(state, :git_stage_all) do
    git_action(state, fn git_root -> Minga.Git.stage(git_root, ".") end, "Staged all changes")
  end

  defp dispatch_action(state, :git_unstage_all) do
    git_action(state, fn git_root -> Minga.Git.unstage_all(git_root) end, "Unstaged all")
  end

  defp dispatch_action(state, {:git_commit, message}) do
    commit_from_gui(state, message, false)
  end

  defp dispatch_action(state, {:git_commit, message, amend?}) do
    commit_from_gui(state, message, amend?)
  end

  defp dispatch_action(state, :git_push) do
    Commands.Git.execute(state, :git_push)
  end

  defp dispatch_action(state, :git_pull) do
    Commands.Git.execute(state, :git_pull)
  end

  defp dispatch_action(state, :git_fetch) do
    Commands.Git.execute(state, :git_fetch)
  end

  defp dispatch_action(state, {:git_commit_amend, message}) do
    commit_from_gui(state, message, true)
  end

  defp dispatch_action(state, {:workspace_close, _ws_id} = action) do
    {shell_state, workspace} =
      state.shell.handle_gui_action(state.shell_state, state.workspace, action)

    state
    |> EditorState.update_shell_state(fn _shell_state -> shell_state end)
    |> EditorState.set_workspace(workspace)
    |> EditorState.sync_agent_ui_from_active_workspace()
  end

  defp dispatch_action(state, {:workspace_rename, _ws_id, _name} = action) do
    {shell_state, workspace} =
      state.shell.handle_gui_action(state.shell_state, state.workspace, action)

    %{state | shell_state: shell_state, workspace: workspace}
  end

  defp dispatch_action(state, {:workspace_set_icon, _ws_id, _icon} = action) do
    {shell_state, workspace} =
      state.shell.handle_gui_action(state.shell_state, state.workspace, action)

    %{state | shell_state: shell_state, workspace: workspace}
  end

  defp dispatch_action(state, {:space_leader_chord, codepoint, modifiers}) do
    MingaEditor.Input.CUA.SpaceLeader.handle_chord(state, codepoint, modifiers)
  end

  defp dispatch_action(state, {:space_leader_retract, codepoint, modifiers}) do
    MingaEditor.Input.CUA.SpaceLeader.handle_retract(state, codepoint, modifiers)
  end

  defp dispatch_action(
         %{workspace: %{buffers: %{active: buf}}} = state,
         {:find_pasteboard_search, text, direction}
       )
       when is_pid(buf) do
    # Set the search pattern and execute search_next/search_prev
    state =
      EditorState.update_search(state, &SearchData.record(&1, text, :forward))

    cmd = if direction == 1, do: :search_prev, else: :search_next
    MingaEditor.Commands.execute(state, cmd)
  end

  defp dispatch_action(state, {:scroll_to_line, line}) do
    # Scroll the active window's viewport to the target line.
    active_win_id = state.workspace.windows.active
    win_map = state.workspace.windows.map

    case Map.get(win_map, active_win_id) do
      nil ->
        state

      window ->
        vp = window.viewport
        new_vp = Viewport.put_top(vp, max(line, 0))
        new_win = MingaEditor.Window.set_viewport(window, new_vp)
        new_map = Map.put(win_map, active_win_id, new_win)

        new_state =
          EditorState.update_windows(state, &Windows.set_map(&1, new_map))

        Renderer.render_or_async(new_state)
    end
  end

  defp dispatch_action(state, {:fold_toggle_at_line, window_id, line}) do
    Commands.Folding.execute_at_line(state, window_id, line)
  end

  defp dispatch_action(state, :cmd_copy) do
    Commands.Editing.execute(state, :cmd_copy)
  end

  defp dispatch_action(state, :cmd_cut) do
    Commands.Editing.execute(state, :cmd_cut)
  end

  defp dispatch_action(state, {:git_open_file, path}) do
    case MingaEditor.resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        abs_path = Path.join(git_root, path)
        BufferRegistry.open_file_by_path(state, abs_path)
    end
  end

  defp dispatch_action(state, {:git_open_diff, path, section}) do
    case MingaEditor.resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        open_git_diff_from_panel(state, git_root, path, section)
    end
  end

  defp dispatch_action(state, :git_pull_and_retry) do
    state
    |> EditorState.clear_git_toast()
    |> Commands.Git.execute(:git_pull_and_retry)
  end

  # ── GUI search toolbar actions ──────────────────────────────────────

  defp dispatch_action(
         %{workspace: %{buffers: %{active: buf}}} = state,
         {:search_query, query, flags}
       )
       when is_pid(buf) do
    decoded = ProtocolGUI.decode_search_flags(flags)
    replace_mode = decoded[:replace_mode]
    case_sensitive = decoded[:case_sensitive]
    whole_word = decoded[:whole_word]
    regex = decoded[:regex]

    state =
      EditorState.update_search(state, fn search ->
        search
        |> SearchData.update_gui_search_flags(case_sensitive, whole_word, regex)
        |> SearchData.set_gui_replace_mode(replace_mode)
        |> SearchData.record(query, :forward)
      end)

    if query != "" do
      content = Buffer.content(buf)
      search_opts = gui_search_opts(state)

      case Minga.Editing.search_next(content, query, Buffer.cursor(buf), :forward, search_opts) do
        nil ->
          state

        {line, col} ->
          Buffer.move_to(buf, {line, col})
          state
      end
    else
      state
    end
  end

  defp dispatch_action(state, {:search_query, _query, _flags}), do: state

  defp dispatch_action(%{workspace: %{search: search}} = state, :search_next)
       when search.last_pattern != nil do
    MingaEditor.Commands.execute(state, :search_next)
  end

  defp dispatch_action(state, :search_next), do: state

  defp dispatch_action(%{workspace: %{search: search}} = state, :search_prev)
       when search.last_pattern != nil do
    MingaEditor.Commands.execute(state, :search_prev)
  end

  defp dispatch_action(state, :search_prev), do: state

  defp dispatch_action(
         %{workspace: %{buffers: %{active: buf}, search: %{last_pattern: pattern}}} = state,
         {:search_replace, replacement}
       )
       when is_pid(buf) and is_binary(pattern) and pattern != "" do
    content = Buffer.content(buf)
    cursor = Buffer.cursor(buf)
    search_opts = gui_search_opts(state)

    case Minga.Editing.search_next(content, pattern, cursor, :forward, search_opts) do
      nil ->
        EditorState.set_status(state, "No more matches")

      {line, col} ->
        Buffer.move_to(buf, {line, col})
        match_len = compute_match_len(content, pattern, line, col, search_opts)
        new_content = replace_single_match(content, line, col, match_len, replacement)
        Buffer.replace_content(buf, new_content)
        MingaEditor.Commands.execute(state, :search_next)
    end
  end

  defp dispatch_action(state, {:search_replace, _}), do: state

  defp dispatch_action(
         %{workspace: %{buffers: %{active: buf}, search: %{last_pattern: pattern}}} = state,
         {:search_replace_all, replacement}
       )
       when is_pid(buf) and is_binary(pattern) and pattern != "" do
    content = Buffer.content(buf)
    search_opts = gui_search_opts(state)

    {new_content, count} =
      Minga.Editing.substitute(content, pattern, replacement, true, search_opts)

    if count > 0 do
      Buffer.replace_content(buf, new_content)
      msg = if count == 1, do: "1 replacement", else: "#{count} replacements"
      EditorState.set_status(state, msg)
    else
      EditorState.set_status(state, "No matches to replace")
    end
  end

  defp dispatch_action(state, {:search_replace_all, _}), do: state

  defp dispatch_action(state, :search_dismiss) do
    EditorState.update_search(state, &SearchData.dismiss_gui_search/1)
  end

  # Catch-all for unrecognized actions: log and return state unchanged.
  defp dispatch_action(state, action) do
    Minga.Log.warning(:editor, "[gui_action] unrecognized action: #{inspect(action)}")
    state
  end

  # ── Git commit helpers ──────────────────────────────────────────────

  @spec commit_from_gui(state(), String.t(), boolean()) :: state()
  defp commit_from_gui(state, message, amend?) do
    case MingaEditor.resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        opts = if amend?, do: [amend: true], else: []
        result = Minga.Git.commit(git_root, message, opts)
        MingaEditor.refresh_git_repo(git_root)
        commit_status(state, result, amend?)
    end
  end

  @spec commit_status(state(), {:ok, String.t()} | {:error, String.t()}, boolean()) :: state()
  defp commit_status(state, {:ok, hash}, true),
    do: EditorState.set_status(state, "Amended #{hash}")

  defp commit_status(state, {:ok, hash}, false),
    do: EditorState.set_status(state, "Committed #{hash}")

  defp commit_status(state, {:error, reason}, true),
    do: EditorState.set_status(state, "Amend failed: #{reason}")

  defp commit_status(state, {:error, reason}, false),
    do: EditorState.set_status(state, "Commit failed: #{reason}")

  # ── Git diff helpers ────────────────────────────────────────────────

  @spec open_git_diff_from_panel(state(), String.t(), String.t(), non_neg_integer()) :: state()
  defp open_git_diff_from_panel(state, git_root, path, section) do
    entries = git_status_panel_entries(state)

    matches =
      case section do
        section when section in 0..3 ->
          Enum.filter(entries, &git_status_entry_matches?(&1, path, section))

        _legacy ->
          Enum.filter(entries, &(&1.path == path))
      end

    case matches do
      [%Git.StatusEntry{} = entry] ->
        open_git_diff_for_entry(state, git_root, entry)

      [] ->
        EditorState.set_status(state, "No git diff entry for #{path}")

      [_ | [_ | _]] ->
        EditorState.set_status(
          state,
          "Ambiguous git diff entry for #{path}; use section-aware diff"
        )
    end
  end

  @spec git_status_entry_matches?(Git.StatusEntry.t(), String.t(), non_neg_integer()) :: boolean()
  defp git_status_entry_matches?(%Git.StatusEntry{} = entry, path, section) do
    entry.path == path && git_status_section(entry) == section
  end

  @spec git_status_section(Git.StatusEntry.t()) :: non_neg_integer()
  defp git_status_section(%Git.StatusEntry{staged: true}), do: 0
  defp git_status_section(%Git.StatusEntry{status: :untracked}), do: 2
  defp git_status_section(%Git.StatusEntry{status: :conflict}), do: 3
  defp git_status_section(%Git.StatusEntry{}), do: 1

  @spec git_status_panel_entries(state()) :: [Git.StatusEntry.t()]
  defp git_status_panel_entries(state) do
    case EditorState.git_status_panel(state) do
      nil -> []
      panel -> Map.get(panel, :entries) || []
    end
  end

  @spec open_git_diff_for_entry(state(), String.t(), Git.StatusEntry.t()) :: state()
  defp open_git_diff_for_entry(state, git_root, %Git.StatusEntry{} = entry) do
    abs_path = git_status_abs_path(git_root, entry.path)
    git_path = Path.relative_to(abs_path, git_root)
    git_entry = %{entry | path: git_path}

    case git_diff_content(git_root, abs_path, git_entry) do
      {:ok, current_content} ->
        Commands.Git.open_diff_for_path(state, git_root, git_path, abs_path, current_content,
          staged: entry.staged
        )

      {:error, message} ->
        EditorState.set_status(state, message)
    end
  end

  @spec git_diff_content(String.t(), String.t(), Git.StatusEntry.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp git_diff_content(_git_root, _abs_path, %Git.StatusEntry{status: :deleted}) do
    {:ok, ""}
  end

  defp git_diff_content(git_root, _abs_path, %Git.StatusEntry{path: rel_path, staged: true}) do
    case Git.show_staged(git_root, rel_path) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, "Could not read staged file: #{rel_path}"}
    end
  end

  defp git_diff_content(_git_root, abs_path, %Git.StatusEntry{}) do
    case File.read(abs_path) do
      {:ok, current_content} -> {:ok, current_content}
      {:error, reason} -> {:error, "Could not read file: #{inspect(reason)}"}
    end
  end

  @spec git_relative_path(String.t(), String.t()) :: String.t()
  defp git_relative_path(git_root, path) do
    git_root
    |> git_status_abs_path(path)
    |> Path.relative_to(git_root)
  end

  @spec git_status_abs_path(String.t(), String.t()) :: String.t()
  defp git_status_abs_path(git_root, path) do
    project_root = Minga.Project.resolve_root()

    if String.starts_with?(Path.expand(project_root), Path.expand(git_root)) do
      Path.join(project_root, path)
    else
      Path.join(git_root, path)
    end
  end

  # ── Git action helper ──────────────────────────────────────────────

  @spec git_action(state(), (String.t() -> :ok | {:error, String.t()}), String.t()) :: state()
  defp git_action(state, operation, success_msg) when is_binary(success_msg) do
    git_root = MingaEditor.resolve_git_root()

    if git_root do
      case operation.(git_root) do
        :ok ->
          MingaEditor.refresh_git_repo(git_root)
          EditorState.set_status(state, success_msg)

        {:error, reason} ->
          EditorState.set_status(state, "Git error: #{reason}")
      end
    else
      EditorState.set_status(state, "Not in a git repository")
    end
  end

  # ── Completion helpers ─────────────────────────────────────────────

  @spec accept_visible_completion(state(), Completion.t(), non_neg_integer()) :: state()
  defp accept_visible_completion(state, comp, index) do
    {visible, _selected_offset} = Completion.visible_items(comp)

    case Enum.at(visible, index) do
      nil ->
        state

      _item ->
        updated = Completion.select_visible(comp, index)

        MingaEditor.do_accept_completion(
          MingaEditor.State.ModalOverlay.update_completion(state, fn _ -> updated end),
          updated
        )
    end
  end

  # ── File tree helpers ──────────────────────────────────────────────

  # Project.switch/1 is a cast; the picker opens against current state while the
  # file cache rebuilds asynchronously. BEAM message ordering from the Editor
  # process guarantees the cast reaches Project before any subsequent call.
  @spec open_dropped_directory(state(), String.t()) :: state()
  defp open_dropped_directory(state, dir_path) do
    Minga.Project.switch(dir_path)
    PickerUI.open(state, MingaEditor.UI.Picker.FileSource)
  end

  # Moves the tree cursor to a specific index (used by GUI context menu / header actions).
  @spec move_tree_cursor(state(), non_neg_integer()) :: state()
  defp move_tree_cursor(%{workspace: %{file_tree: %{tree: nil}}} = state, _index), do: state

  defp move_tree_cursor(state, index) do
    EditorState.update_file_tree(state, fn file_tree ->
      FileTreeState.set_tree(file_tree, FileTree.select(file_tree.tree, index))
    end)
  end

  # Moves the file tree cursor to the given index and performs the action.
  @spec gui_tree_action(state(), non_neg_integer(), :click | :toggle) :: state()
  defp gui_tree_action(%{workspace: %{file_tree: %{tree: nil}}} = state, _index, _action),
    do: state

  defp gui_tree_action(state, index, action) do
    state = move_tree_cursor(state, index)

    case action do
      :click -> Commands.FileTree.open_or_toggle(state)
      :toggle -> Commands.FileTree.open_or_toggle(state)
    end
  end

  @spec open_file_tree_entry_in_split(state(), non_neg_integer()) :: state()
  defp open_file_tree_entry_in_split(%{workspace: %{file_tree: %{tree: nil}}} = state, _index) do
    state
  end

  defp open_file_tree_entry_in_split(state, index) do
    state =
      state
      |> move_tree_cursor(index)
      |> unfocus_file_tree_for_split()

    case FileTree.selected_entry(state.workspace.file_tree.tree) do
      %{dir?: false, path: path} ->
        state
        |> Commands.Movement.execute(:split_vertical)
        |> Commands.Movement.execute(:window_right)
        |> open_file_by_path_in_active_window(path)

      %{dir?: true} ->
        state

      nil ->
        state
    end
  end

  @spec unfocus_file_tree_for_split(state()) :: state()
  defp unfocus_file_tree_for_split(state) do
    state
    |> EditorState.update_file_tree(&MingaEditor.State.FileTree.unfocus/1)
    |> EditorState.set_keymap_scope(:editor)
  end

  # ── Hover open action ──────────────────────────────────────────────

  @spec accept_hover_open_action(state()) :: state()
  defp accept_hover_open_action(state) do
    case EditorState.hover_popup(state) do
      %MingaEditor.HoverPopup{open_action: action} when action != nil ->
        state = EditorState.dismiss_hover_popup(state)
        execute_hover_open_action(state, action)

      _ ->
        state
    end
  end

  @spec execute_hover_open_action(state(), MingaEditor.HoverPopup.open_action()) :: state()
  defp execute_hover_open_action(state, {:goto_location, uri, line, col}) do
    LspActions.open_location(state, uri, line, col)
  end

  defp execute_hover_open_action(state, action) when is_atom(action) do
    case Commands.execute(state, action) do
      {new_state, _action} -> new_state
      new_state -> new_state
    end
  end

  # ── Tab helpers ───────────────────────────────────────────────────

  @spec reorder_tab(state(), Tab.id(), non_neg_integer()) :: state()
  defp reorder_tab(state, id, new_index) do
    update_tab_bar(state, &TabBar.reorder_tab(&1, id, new_index))
  end

  @spec update_tab_bar(state(), (TabBar.t() -> TabBar.t())) :: state()
  defp update_tab_bar(state, fun) when is_function(fun, 1) do
    case EditorState.tab_bar(state) do
      %TabBar{} = tb -> EditorState.set_tab_bar(state, fun.(tb))
      nil -> state
    end
  end

  # ── Tab path helpers ───────────────────────────────────────────────

  @spec copy_tab_path(state(), Tab.id()) :: state()
  defp copy_tab_path(state, id) do
    case tab_file_path(state, id) do
      nil ->
        EditorState.set_status(state, "Tab has no file path")

      path ->
        Clipboard.write_async(path)
        maybe_send_gui_clipboard_write(state, path)
        EditorState.set_status(state, "Copied #{path}")
    end
  end

  @spec maybe_send_gui_clipboard_write(state(), String.t()) :: :ok
  defp maybe_send_gui_clipboard_write(%{port_manager: nil}, _path), do: :ok

  defp maybe_send_gui_clipboard_write(state, path) do
    MingaEditor.Frontend.clipboard_write(state.port_manager, path)
  end

  @spec tab_file_path(state(), Tab.id()) :: String.t() | nil
  defp tab_file_path(state, id) do
    case EditorState.tab_bar(state) do
      %TabBar{} = tb -> tab_file_path_from_tab(state, tb, TabBar.get(tb, id))
      nil -> nil
    end
  end

  @spec tab_file_path_from_tab(state(), TabBar.t(), Tab.t() | nil) :: String.t() | nil
  defp tab_file_path_from_tab(_state, _tb, nil), do: nil
  defp tab_file_path_from_tab(_state, _tb, %Tab{kind: :agent}), do: nil

  defp tab_file_path_from_tab(state, %TabBar{active_id: active_id} = tb, %Tab{id: id}) do
    case id == active_id do
      true -> active_buffer_path(state)
      false -> inactive_tab_path(TabBar.get(tb, id))
    end
  end

  @spec active_buffer_path(state()) :: String.t() | nil
  defp active_buffer_path(%{workspace: %{buffers: %{active: buf}}}) when is_pid(buf) do
    Buffer.file_path(buf)
  end

  defp active_buffer_path(_state), do: nil

  @spec inactive_tab_path(Tab.t() | nil) :: String.t() | nil
  defp inactive_tab_path(%Tab{context: context}) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: pid}} when is_pid(pid) -> Buffer.file_path(pid)
      _ -> nil
    end
  end

  defp inactive_tab_path(_tab), do: nil

  # ── LSP resync helpers ─────────────────────────────────────────────

  @spec buffers_for_lsp_resync(state()) :: [pid()]
  defp buffers_for_lsp_resync(state) do
    active_buffers = Enum.filter(state.workspace.buffers.list, &is_pid/1)

    tab_buffers =
      case EditorState.tab_bar(state) do
        %MingaEditor.State.TabBar{tabs: tabs} -> Enum.flat_map(tabs, &tab_buffer_list/1)
        _ -> []
      end

    Enum.uniq(active_buffers ++ tab_buffers)
  end

  @spec tab_buffer_list(MingaEditor.State.Tab.t() | term()) :: [pid()]
  defp tab_buffer_list(%MingaEditor.State.Tab{context: context}) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{list: buffers}} -> Enum.filter(buffers, &is_pid/1)
      _ -> []
    end
  end

  defp tab_buffer_list(_tab), do: []

  # ── Git repo helpers ───────────────────────────────────────────────

  @spec refresh_current_git_repo() :: :ok
  defp refresh_current_git_repo do
    case MingaEditor.resolve_git_root() do
      nil -> :ok
      git_root -> MingaEditor.refresh_git_repo(git_root)
    end
  end

  # ── Window helpers ─────────────────────────────────────────────────

  @spec open_file_by_path_in_active_window(state(), String.t()) :: state()
  defp open_file_by_path_in_active_window(state, abs_path) do
    case BufferRegistry.file_tab_for_path_in_active_workspace(state, abs_path) do
      %Tab{} = tab ->
        open_tab_buffer_in_active_window(state, tab, abs_path)

      nil ->
        case Commands.start_buffer(abs_path, EditorState.options_server(state)) do
          {:ok, pid} -> register_buffer_in_active_window(state, pid, abs_path)
          {:error, _reason} -> EditorState.set_status(state, "Could not open #{abs_path}")
        end
    end
  end

  @spec open_tab_buffer_in_active_window(state(), Tab.t(), String.t()) :: state()
  defp open_tab_buffer_in_active_window(state, tab, abs_path) do
    case tab_active_buffer(tab) do
      pid when is_pid(pid) -> show_buffer_in_active_window(state, pid)
      nil -> EditorState.set_status(state, "Could not open #{abs_path}")
    end
  end

  @spec show_buffer_in_active_window(state(), pid()) :: state()
  defp show_buffer_in_active_window(state, pid) when is_pid(pid) do
    state
    |> EditorState.update_buffers(fn buffers ->
      case Enum.find_index(buffers.list, &(&1 == pid)) do
        nil -> Buffers.add(buffers, pid)
        idx -> Buffers.switch_to(buffers, idx)
      end
    end)
    |> EditorState.sync_active_window_buffer()
  end

  @spec tab_active_buffer(Tab.t()) :: pid() | nil
  defp tab_active_buffer(%Tab{context: context}) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: pid}} when is_pid(pid) -> pid
      _ -> nil
    end
  end

  @spec register_buffer_in_active_window(state(), pid(), String.t()) :: state()
  defp register_buffer_in_active_window(state, buffer_pid, file_path) do
    state =
      state
      |> EditorState.update_buffers(&Buffers.add(&1, buffer_pid))
      |> EditorState.sync_active_window_buffer()
      |> EditorState.monitor_buffer(buffer_pid)

    state = MingaEditor.log_message(state, "Opened: #{file_path}")

    Minga.Events.broadcast(
      :buffer_opened,
      %Minga.Events.BufferEvent{buffer: buffer_pid, path: file_path},
      EditorState.events_registry(state)
    )

    state = HighlightSync.setup_for_buffer_pid(state, buffer_pid)

    if state.backend != :headless do
      Process.send_after(self(), :request_code_lens_and_inlay_hints, 800)
    end

    state
  end

  # ── Vim mode state helper ──────────────────────────────────────────

  @spec set_vim_mode_state(state(), term()) :: state()
  defp set_vim_mode_state(state, new_ms) do
    EditorState.update_editing(state, &VimState.set_mode_state(&1, new_ms))
  end

  @spec normalize_command_result(state() | {state(), term()}) :: state()
  defp normalize_command_result({new_state, _action}), do: new_state
  defp normalize_command_result(new_state), do: new_state

  @spec route_panel_action_to_extension(String.t(), atom(), map()) :: :ok
  defp route_panel_action_to_extension(ext_name, action_name, context) do
    ext_atom = String.to_existing_atom(ext_name)

    case Minga.Extension.Registry.get(Minga.Extension.Registry, ext_atom) do
      {:ok, %{pid: pid}} when is_pid(pid) ->
        send(pid, {:panel_action, action_name, context})
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @spec replace_single_match(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: String.t()
  defp replace_single_match(content, match_line, match_col, match_len, replacement) do
    lines = :binary.split(content, "\n", [:global])

    List.update_at(lines, match_line, fn line ->
      line_len = byte_size(line)

      if match_col + match_len <= line_len do
        before = binary_part(line, 0, match_col)
        after_match = binary_part(line, match_col + match_len, line_len - match_col - match_len)
        before <> replacement <> after_match
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  @spec gui_search_opts(state()) :: Minga.Editing.Search.search_opts()
  defp gui_search_opts(%{workspace: %{search: %{gui_search: %{} = gs}}}) do
    [
      case_sensitive: Map.get(gs, :case_sensitive, true),
      whole_word: Map.get(gs, :whole_word, false),
      regex: Map.get(gs, :regex, false)
    ]
  end

  defp gui_search_opts(_state), do: []

  @spec compute_match_len(
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Minga.Editing.Search.search_opts()
        ) :: non_neg_integer()
  defp compute_match_len(_content, pattern, _match_line, _match_col, []),
    do: byte_size(pattern)

  defp compute_match_len(content, pattern, match_line, match_col, opts) do
    use_regex = Keyword.get(opts, :regex, false)
    case_insensitive = not Keyword.get(opts, :case_sensitive, true)

    if use_regex or case_insensitive do
      line = content |> :binary.split("\n", [:global]) |> Enum.at(match_line)
      searchable = binary_part(line, match_col, byte_size(line) - match_col)
      regex_match_len(pattern, searchable, use_regex, case_insensitive)
    else
      byte_size(pattern)
    end
  end

  @spec regex_match_len(String.t(), String.t(), boolean(), boolean()) :: non_neg_integer()
  defp regex_match_len(pattern, searchable, use_regex, case_insensitive) do
    regex_source = if use_regex, do: pattern, else: Regex.escape(pattern)
    regex_opts = if case_insensitive, do: "i", else: ""

    with {:ok, regex} <- Regex.compile(regex_source, regex_opts),
         [{0, len}] <- Regex.run(regex, searchable, return: :index, capture: :first) do
      len
    else
      _ -> byte_size(pattern)
    end
  end
end
