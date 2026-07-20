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
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.Observatory, as: ObservatoryState
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias Minga.Clipboard
  alias Minga.Editing.Completion
  alias Minga.FileWatcher
  alias Minga.Git
  alias Minga.LSP.Supervisor, as: LspSupervisor
  alias Minga.LSP.SyncServer, as: LspSyncServer

  alias MingaEditor.Agent.SemanticUI.Registry, as: SemanticUIRegistry
  alias MingaEditor.Agent.UIState
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.GitMutation
  alias MingaEditor.Effects.GitMutationAdmission
  alias MingaEditor.GitRepositoryResolver
  alias MingaEditor.FileTree.Freshness, as: FileTreeFreshness
  alias MingaEditor.Commands
  alias MingaEditor.Extension.EventWorkflow, as: ExtensionEventWorkflow
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.HighlightSync
  alias MingaEditor.Layout
  alias MingaEditor.LspActions
  alias MingaEditor.Input.Observatory
  alias MingaEditor.MinibufferData
  alias MingaEditor.UI.Popup.Lifecycle, as: PopupLifecycle
  alias MingaEditor.PickerUI
  alias MingaEditor.Renderer
  alias MingaEditor.Session.State
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.WorkspaceWorkflow
  alias MingaEditor.Window

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationFeedback
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
  @git_root_resolver_key :__gui_action_git_root_resolver__

  @spec dispatch(state(), Protocol.GUI.gui_action(), keyword()) :: state()
  def dispatch(state, action, opts \\ []) do
    previous_resolver = Process.get(@git_root_resolver_key, :__unset__)

    case Keyword.fetch(opts, :git_root_resolver) do
      {:ok, resolver} -> Process.put(@git_root_resolver_key, resolver)
      :error -> :ok
    end

    try do
      dispatch_action(state, action)
    after
      restore_git_root_resolver(previous_resolver)
    end
  end

  @spec restore_git_root_resolver(:__unset__ | {module(), term()}) :: term()
  defp restore_git_root_resolver(:__unset__), do: Process.delete(@git_root_resolver_key)

  defp restore_git_root_resolver(previous_resolver),
    do: Process.put(@git_root_resolver_key, previous_resolver)

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

    workspace = State.invalidate_all_windows(state.workspace)
    state = %{state | workspace: workspace}
    state |> Layout.invalidate() |> Renderer.render_or_async()
  end

  defp dispatch_action(state, {:system_will_unmount, volume_path}) do
    handle_volume_will_unmount(state, volume_path)
  end

  defp dispatch_action(state, {:power_thermal_state, low_power?, thermal_state}) do
    Minga.Log.info(
      :editor,
      "Power/thermal state: low_power=#{low_power?}, thermal=#{inspect(thermal_state)}"
    )

    state = %{
      state
      | frontend:
          MingaEditor.State.Frontend.report_resource_pressure(
            state.frontend,
            low_power?,
            thermal_state
          )
    }

    Minga.Events.broadcast(
      :power_thermal_state_changed,
      %Minga.Events.PowerThermalStateEvent{
        low_power?: low_power?,
        thermal_state: thermal_state
      },
      state.extension_surfaces.events_registry
    )

    state
  end

  defp dispatch_action(state, :config_query) do
    # The settings panel queries the full config snapshot when it opens (#2119).
    # config_state is emitted in-frame and the adapter fingerprint-caches it, so an
    # unchanged snapshot would be suppressed. config_query is an explicit "re-send
    # the current state" pull, so reset the frontend render state to drop the
    # adapter caches and force the next frame to re-emit config_state (and every
    # other surface), then render.
    state
    |> MingaEditor.refresh_gui_config_state()
    |> EditorState.reset_frontend_render_state()
    |> Renderer.render_or_async()
  end

  defp dispatch_action(state, {:config_update, name, value}) do
    if MingaEditor.Frontend.Protocol.GUI.settings_option?(name) do
      case Minga.Config.Options.set(state.interaction.options_server, name, value) do
        {:ok, persisted_value} ->
          Minga.Config.Options.mark_explicit(state.interaction.options_server, name)
          Minga.Config.Writer.persist(name, persisted_value)

          state
          |> MingaEditor.apply_runtime_config_option(name, persisted_value)
          |> MingaEditor.refresh_gui_config_state()
          |> Renderer.render_or_async()

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
    %{state | feedback: MingaEditor.State.Feedback.dismiss_notification(state.feedback, id)}
  end

  defp dispatch_action(state, {:notification_action, notification_id, action_id}) do
    case MingaEditor.UI.NotificationCenter.action(
           state.feedback.notifications,
           notification_id,
           action_id
         ) do
      %{dispatch: {:command, command}} ->
        %{
          state
          | feedback:
              MingaEditor.State.Feedback.dismiss_notification(state.feedback, notification_id)
        }
        |> Commands.execute(command)
        |> normalize_command_result()

      %{dispatch: {:event, event, payload}} ->
        Minga.Events.broadcast(event, payload, state.extension_surfaces.events_registry)
        state

      _ ->
        state
    end
  end

  @min_font_size 8
  @max_font_size 72

  defp dispatch_action(%MingaEditor.State{} = state, {:font_size_adjust, direction}) do
    options_server = state.interaction.options_server
    config_size = Minga.Config.Options.get(options_server, :font_size)

    new_size =
      case direction do
        :increase -> min((state.appearance.font_size_override || config_size) + 1, @max_font_size)
        :decrease -> max((state.appearance.font_size_override || config_size) - 1, @min_font_size)
        :reset -> nil
      end

    state = %{
      state
      | appearance: MingaEditor.State.Appearance.override_font_size(state.appearance, new_size)
    }

    Startup.send_font_config(state)
    EditorState.reset_frontend_render_state(state)
  end

  defp dispatch_action(
         %{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state,
         {:observatory_inspect, pid_string}
       ),
       do: Observatory.inspect_process(state, pid_string)

  defp dispatch_action(state, {:observatory_inspect, _pid_string}), do: state

  defp dispatch_action(state, {:timeline_navigate, index}) do
    MingaEditor.Commands.EditTimeline.navigate_to_index(state, index)
  end

  defp dispatch_action(state, {:extension_panel_action, ext_name, action_name, context}) do
    route_panel_action_to_extension(state, ext_name, action_name, context)
  end

  defp dispatch_action(state, :agent_approve), do: dispatch_to_active_shell(state, :agent_approve)

  defp dispatch_action(state, :agent_request_changes),
    do: dispatch_to_active_shell(state, :agent_request_changes)

  defp dispatch_action(state, :agent_dismiss), do: dispatch_to_active_shell(state, :agent_dismiss)

  # Agent-chat pin intents (#2654 slice 2). A frontend that owns its transcript
  # scroll locally reports crossing the bottom threshold; the BEAM tracks the
  # pin flag as the authority without moving the offset, so a round-trip
  # frontend's concrete scroll position is untouched. No render is forced: the
  # reporting frontend already reflects the change locally, and the flag only
  # affects the auto-follow decision on the next streaming frame.
  defp dispatch_action(state, :chat_scrolled_away_from_bottom) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
      state,
      (&UIState.set_pinned(&1, false)).(state.workspace.agent_ui)
    )
  end

  defp dispatch_action(state, :chat_returned_to_bottom) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
      state,
      (&UIState.set_pinned(&1, true)).(state.workspace.agent_ui)
    )
  end

  defp dispatch_action(state, {:select_tab, id}) do
    MingaEditor.TabWorkflow.switch(state, id)
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
    # Delegate to the shell: Traditional switches to the target tab when needed; tab-bar-less shells return unchanged.
    state = handle_shell_gui_action(state, {:close_tab, id})

    # Only close the buffer when the active shell exposes a tab.
    # The shell runtime returns nil when there are no tabs.
    case MingaEditor.Shell.Runtime.active_tab(state.shell_runtime) do
      # Closing the last file tab lands on the launchpad, never quits the
      # app (#2689): kill the buffer so the empty state has zero buffers.
      %MingaEditor.State.Tab{kind: :file} ->
        if last_file_tab?(state) do
          Commands.BufferManagement.execute(state, :kill_buffer)
        else
          Commands.BufferManagement.execute(state, :force_quit)
        end

      nil ->
        state

      _tab ->
        Commands.BufferManagement.execute(state, :force_quit)
    end
  end

  defp dispatch_action(state, {:empty_state_activate, item_id}) do
    Commands.Launchpad.activate(state, item_id)
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
        state = %{state | workspace: State.set_file_tree(state.workspace, ft)}
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
    case MingaEditor.Shell.Traditional.ModalWorkflow.completion(state) do
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
    shell_state =
      MingaEditor.Shell.Traditional.State.install_bottom_panel(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        MingaEditor.BottomPanel.toggle(state.shell_runtime.state.bottom_panel)
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  defp dispatch_action(state, {:toggle_panel, 2}) do
    execute_registered_command(state, :git_status_toggle)
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

  defp dispatch_action(state, {:sidebar_action, sidebar_id, kind, action}) do
    sidebar_registry = state.extension_surfaces.sidebar_registry

    case Sidebar.get(sidebar_registry, sidebar_id) do
      nil ->
        dispatch_missing_registered_sidebar_action(state, sidebar_id, kind, action)

      _sidebar ->
        Sidebar.dispatch_action(sidebar_registry, state, sidebar_id, action, %{kind: kind})
    end
  end

  defp dispatch_action(state, :new_tab) do
    Commands.BufferManagement.execute(state, :new_buffer)
  end

  defp dispatch_action(state, {:panel_switch_tab, tab_index}) do
    shell_state =
      MingaEditor.Shell.Traditional.State.install_bottom_panel(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        MingaEditor.BottomPanel.switch_tab(
          state.shell_runtime.state.bottom_panel,
          tab_index
        )
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  defp dispatch_action(state, :panel_dismiss) do
    shell_state =
      MingaEditor.Shell.Traditional.State.install_bottom_panel(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        MingaEditor.BottomPanel.dismiss(state.shell_runtime.state.bottom_panel)
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  defp dispatch_action(state, {:panel_resize, height_percent}) do
    shell_state =
      MingaEditor.Shell.Traditional.State.install_bottom_panel(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        MingaEditor.BottomPanel.resize(
          state.shell_runtime.state.bottom_panel,
          height_percent
        )
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  defp dispatch_action(state, {:open_file, path}) do
    if File.dir?(path) do
      open_dropped_directory(state, path)
    else
      BufferRegistry.open_file_by_path(state, path)
    end
  end

  defp dispatch_action(state, {:agent_tool_toggle, message_id}) do
    session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)

    if session do
      try do
        AgentSession.toggle_tool_collapse(session, message_id)
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
        clamped = MinibufferData.clamp_index(index, Enum.count(candidates))

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

  defp dispatch_action(state, {:execute_command, "workspace_goto_id:" <> workspace_id}) do
    case Integer.parse(workspace_id) do
      {id, ""} when id >= 0 ->
        state
        |> Commands.execute({:workspace_goto, id})
        |> normalize_command_result()

      _other ->
        Minga.Log.warning(
          :editor,
          "[execute_command] invalid workspace id command: workspace_goto_id:#{workspace_id}"
        )

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
    git_action(state, "Staging #{path}…", :stage, "Staged #{path}", path: path)
  end

  defp dispatch_action(state, {:git_unstage_file, path}) do
    git_action(state, "Unstaging #{path}…", :unstage, "Unstaged #{path}", path: path)
  end

  defp dispatch_action(state, {:git_discard_file, path}) do
    git_action(state, "Discarding #{path}…", :discard, "Discarded #{path}", path: path)
  end

  defp dispatch_action(state, :git_stage_all) do
    git_action(state, "Staging all changes…", :stage_all, "Staged all changes")
  end

  defp dispatch_action(state, :git_unstage_all) do
    git_action(state, "Unstaging all…", :unstage_all, "Unstaged all")
  end

  defp dispatch_action(state, {:git_commit, message}) do
    commit_from_gui(state, message, false)
  end

  defp dispatch_action(state, {:git_commit, message, amend?}) do
    commit_from_gui(state, message, amend?)
  end

  defp dispatch_action(state, :git_push) do
    execute_registered_command(state, :git_push)
  end

  defp dispatch_action(state, :git_pull) do
    execute_registered_command(state, :git_pull)
  end

  defp dispatch_action(state, :git_fetch) do
    execute_registered_command(state, :git_fetch)
  end

  defp dispatch_action(state, {:git_commit_amend, message}) do
    commit_from_gui(state, message, true)
  end

  defp dispatch_action(state, {:workspace_close, _ws_id} = action) do
    transitioned = handle_shell_gui_action(state, action)

    state
    |> WorkspaceWorkflow.persist_changes(transitioned)
    |> MingaEditor.TabWorkflow.sync_active_workspace_agent_ui()
  end

  defp dispatch_action(state, {:workspace_rename, _ws_id, _name} = action) do
    transitioned = handle_shell_gui_action(state, action)
    WorkspaceWorkflow.persist_changes(state, transitioned)
  end

  defp dispatch_action(state, {:workspace_set_icon, _ws_id, _icon} = action) do
    transitioned = handle_shell_gui_action(state, action)
    WorkspaceWorkflow.persist_changes(state, transitioned)
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
    state =
      %{
        state
        | workspace:
            State.set_search(
              state.workspace,
              (&SearchData.record(&1, text, :forward)).(state.workspace.search)
            )
      }

    cmd = if direction == 1, do: :search_prev, else: :search_next
    MingaEditor.Commands.execute(state, cmd)
  end

  defp dispatch_action(state, {:scroll_to_line, line}) do
    # Scroll the active window's viewport to the target line. This is the
    # scrollbar thumb-drag / track-click commit path (#2665). It gets the same
    # free-scroll treatment as the wheel/trackpad path in `Mouse.apply_scroll_intent`:
    #
    #   * `mark_scroll_echo/2` records the committed top so `settle_scroll_seq/1`
    #     treats it as a frontend-reported echo and does NOT bump `scroll_seq`.
    #     Without this, the drag's own committed anchor would look like a
    #     BEAM-initiated jump and discard the frontend's same-frame local
    #     presentation over resident rows (AC2).
    #   * `record_scroll_event/3` marks `scroll_detach_cursor` so cursor-follow is
    #     suppressed: the viewport stays where it was dragged and the cursor stays
    #     put (VSCode wheel semantics, #2684/#2691). A thumb drag never moves the
    #     cursor, so without this the next frame would re-anchor the viewport to
    #     the cursor line and yank the content back — a settle-jump.
    active_win_id = state.workspace.windows.active
    win_map = state.workspace.windows.map

    case Map.get(win_map, active_win_id) do
      nil ->
        state

      window ->
        vp = window.viewport
        new_vp = Viewport.put_top(vp, max(line, 0))
        new_win = scroll_to_line_commit(window, new_vp)
        new_map = Map.put(win_map, active_win_id, new_win)

        new_state =
          %{
            state
            | workspace:
                State.set_windows(
                  state.workspace,
                  (&Windows.set_map(&1, new_map)).(state.workspace.windows)
                )
          }

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
        NoticeWorkflow.publish(state, "Not in a git repository")

      git_root ->
        abs_path = Path.join(git_root, path)
        BufferRegistry.open_file_by_path(state, abs_path)
    end
  end

  defp dispatch_action(state, {:git_open_diff, path, section}) do
    case MingaEditor.resolve_git_root() do
      nil ->
        NoticeWorkflow.publish(state, "Not in a git repository")

      git_root ->
        open_git_diff_from_panel(state, git_root, path, section)
    end
  end

  defp dispatch_action(state, :git_pull_and_retry) do
    state
    |> MingaEditor.Shell.Traditional.GitToastWorkflow.dismiss()
    |> execute_registered_command(:git_pull_and_retry)
  end

  defp dispatch_action(state, {:picker_query_changed, generation, edit_seq, query}) do
    PickerUI.replace_query(state, generation, edit_seq, query)
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
      %{
        state
        | workspace:
            State.set_search(
              state.workspace,
              (fn search ->
                 search
                 |> SearchData.update_gui_search_flags(case_sensitive, whole_word, regex)
                 |> SearchData.set_gui_replace_mode(replace_mode)
                 |> SearchData.record(query, :forward)
               end).(state.workspace.search)
            )
      }

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

  defp dispatch_action(
         %{workspace: %{buffers: %{active: buf}, search: %{last_pattern: pattern}}} = state,
         :search_next
       )
       when is_pid(buf) and is_binary(pattern) do
    search_opts = gui_search_opts(state)
    content = Buffer.content(buf)
    cursor = Buffer.cursor(buf)

    case Minga.Editing.search_next(content, pattern, cursor, :forward, search_opts) do
      nil ->
        state

      {line, col} ->
        Buffer.move_to(buf, {line, col})
        state
    end
  end

  defp dispatch_action(state, :search_next), do: state

  defp dispatch_action(
         %{workspace: %{buffers: %{active: buf}, search: %{last_pattern: pattern}}} = state,
         :search_prev
       )
       when is_pid(buf) and is_binary(pattern) do
    search_opts = gui_search_opts(state)
    content = Buffer.content(buf)
    cursor = Buffer.cursor(buf)

    case Minga.Editing.search_next(content, pattern, cursor, :backward, search_opts) do
      nil ->
        state

      {line, col} ->
        Buffer.move_to(buf, {line, col})
        state
    end
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
        NoticeWorkflow.publish(state, "No more matches")

      {line, col} ->
        Buffer.move_to(buf, {line, col})
        match_len = compute_match_len(content, pattern, line, col, search_opts)
        new_content = replace_single_match(content, line, col, match_len, replacement)
        Buffer.replace_content(buf, new_content)

        new_cursor = Buffer.cursor(buf)
        new_content2 = Buffer.content(buf)

        case Minga.Editing.search_next(new_content2, pattern, new_cursor, :forward, search_opts) do
          nil ->
            state

          {nl, nc} ->
            Buffer.move_to(buf, {nl, nc})
            state
        end
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
      NoticeWorkflow.publish(state, msg)
    else
      NoticeWorkflow.publish(state, "No matches to replace")
    end
  end

  defp dispatch_action(state, {:search_replace_all, _}), do: state

  defp dispatch_action(state, :search_dismiss) do
    %{
      state
      | workspace:
          State.set_search(
            state.workspace,
            (&SearchData.dismiss_gui_search/1).(state.workspace.search)
          )
    }
  end

  defp dispatch_action(state, {:extension_action, _extension_id, _action, _payload} = action) do
    dispatch_to_active_shell(state, action)
  end

  # Float popup dismiss (#2338). A click outside the rendered float popup but
  # inside its overlay band routes here, the same dismiss intent the keyboard
  # quit key reaches (MingaEditor.Input.Popup). The float popup has two sources
  # (MingaEditor.RenderModel.UI.FloatPopupBuilder), so dismissal mirrors them:
  # an observatory inspection float clears via Observatory.inspect_process("")
  # (set_observatory_inspection nil); a :float popup window closes via the popup
  # lifecycle. Observatory inspection is checked first because it is the higher-
  # priority float source in the builder. With neither present this is a no-op.
  defp dispatch_action(state, :float_popup_dismiss) do
    dismiss_float_popup(state)
  end

  # Catch-all for unrecognized actions: log and return state unchanged.
  defp dispatch_action(state, action) do
    Minga.Log.warning(:editor, "[gui_action] unrecognized action: #{inspect(action)}")
    state
  end

  @spec last_file_tab?(EditorState.t()) :: boolean()
  defp last_file_tab?(%{shell_runtime: %{state: %{tab_bar: %MingaEditor.State.TabBar{} = tb}}}) do
    match?([_single], MingaEditor.State.TabBar.visible_file_tabs(tb))
  end

  defp last_file_tab?(_state), do: false

  @spec dispatch_to_active_shell(EditorState.t(), term()) :: EditorState.t()
  defp dispatch_to_active_shell(state, action) do
    state = MingaEditor.Shell.Workflow.ensure_available(state)
    shell = MingaEditor.Shell.Runtime.module(state.shell_runtime)

    {runtime, workspace} =
      MingaEditor.Shell.Runtime.route_gui_action(
        state.shell_runtime,
        state.workspace,
        action
      )

    state = %{state | shell_runtime: runtime, workspace: workspace}
    after_shell_gui_action(state, shell, action)
  end

  @spec after_shell_gui_action(EditorState.t(), module(), term()) :: EditorState.t()
  defp after_shell_gui_action(state, shell, action) do
    if function_exported?(shell, :after_gui_action, 2) do
      shell.after_gui_action(state, action)
    else
      state
    end
  end

  @spec dispatch_missing_registered_sidebar_action(
          EditorState.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          EditorState.t()
  defp dispatch_missing_registered_sidebar_action(state, sidebar_id, kind, action) do
    if builtin_sidebar_id?(sidebar_id) do
      Minga.Log.warning(
        :editor,
        "Sidebar registry missing #{sidebar_id}; using built-in #{action} fallback"
      )

      dispatch_sidebar_action(state, sidebar_id, kind, action)
    else
      ignored_sidebar_action(state, sidebar_id, kind, action)
    end
  end

  @spec builtin_sidebar_id?(String.t()) :: boolean()
  defp builtin_sidebar_id?(sidebar_id),
    do: sidebar_id in ["file_tree", "git_status", "observatory"]

  @spec dispatch_sidebar_action(EditorState.t(), String.t(), String.t(), String.t()) ::
          EditorState.t()
  defp dispatch_sidebar_action(state, sidebar_id, kind, "toggle") do
    state
    |> dispatch_sidebar_toggle(sidebar_id, kind)
    |> remember_visible_sidebar(sidebar_id)
  end

  defp dispatch_sidebar_action(state, sidebar_id, kind, "activate") do
    state
    |> dispatch_sidebar_activate(sidebar_id, kind)
    |> remember_visible_sidebar(sidebar_id)
  end

  defp dispatch_sidebar_action(state, sidebar_id, kind, action) do
    ignored_sidebar_action(state, sidebar_id, kind, action)
  end

  @spec dispatch_sidebar_toggle(EditorState.t(), String.t(), String.t()) :: EditorState.t()
  defp dispatch_sidebar_toggle(state, "file_tree", _kind),
    do: Commands.FileTree.toggle(state)

  defp dispatch_sidebar_toggle(state, "git_status", _kind),
    do: execute_registered_command(state, :git_status_toggle)

  defp dispatch_sidebar_toggle(state, "observatory", _kind) do
    state
    |> Commands.execute(:toggle_beam_observatory)
    |> normalize_command_result()
  end

  defp dispatch_sidebar_toggle(state, sidebar_id, kind),
    do: ignored_sidebar_action(state, sidebar_id, kind, "toggle")

  @spec dispatch_sidebar_activate(EditorState.t(), String.t(), String.t()) :: EditorState.t()
  defp dispatch_sidebar_activate(state, "file_tree", kind) do
    if sidebar_visible?(state, "file_tree"),
      do: focus_visible_sidebar(state, "file_tree"),
      else: dispatch_sidebar_toggle(state, "file_tree", kind)
  end

  defp dispatch_sidebar_activate(state, "git_status", kind) do
    if sidebar_visible?(state, "git_status"),
      do: focus_visible_sidebar(state, "git_status"),
      else: dispatch_sidebar_toggle(state, "git_status", kind)
  end

  defp dispatch_sidebar_activate(state, "observatory", kind) do
    if sidebar_visible?(state, "observatory"),
      do: focus_visible_sidebar(state, "observatory"),
      else: dispatch_sidebar_toggle(state, "observatory", kind)
  end

  defp dispatch_sidebar_activate(state, sidebar_id, kind),
    do: ignored_sidebar_action(state, sidebar_id, kind, "activate")

  @spec focus_visible_sidebar(EditorState.t(), String.t()) :: EditorState.t()
  defp focus_visible_sidebar(state, "file_tree") do
    file_tree = FileTreeState.focus(state.workspace.file_tree)

    workspace =
      state.workspace
      |> State.set_file_tree(file_tree)
      |> State.set_keymap_scope(:file_tree)

    state = %{state | workspace: workspace}
    state = Layout.invalidate(state)
    workspace = State.invalidate_all_windows(state.workspace)
    %{state | workspace: workspace}
  end

  defp focus_visible_sidebar(state, "git_status") do
    workspace = State.set_keymap_scope(state.workspace, :git_status)
    state = %{state | workspace: workspace}
    state = Layout.invalidate(state)
    workspace = State.invalidate_all_windows(state.workspace)
    %{state | workspace: workspace}
  end

  defp focus_visible_sidebar(state, "observatory") do
    file_tree = FileTreeState.unfocus(state.workspace.file_tree)

    workspace =
      state.workspace
      |> State.set_file_tree(file_tree)
      |> State.set_keymap_scope(:editor)

    state = %{state | workspace: workspace}
    state = Layout.invalidate(state)
    workspace = State.invalidate_all_windows(state.workspace)
    %{state | workspace: workspace}
  end

  @spec remember_visible_sidebar(EditorState.t(), String.t()) :: EditorState.t()
  defp remember_visible_sidebar(state, sidebar_id) do
    if sidebar_visible?(state, sidebar_id) do
      SidebarWorkflow.select(state, sidebar_id)
    else
      SidebarWorkflow.select(state, nil)
    end
  end

  @spec sidebar_visible?(EditorState.t(), String.t()) :: boolean()
  defp sidebar_visible?(state, "file_tree") do
    state.workspace.file_tree
    |> FileTreeState.status()
    |> FileTreeState.visible_status?()
  end

  defp sidebar_visible?(state, "git_status"), do: SidebarWorkflow.git_status_panel(state) != nil
  defp sidebar_visible?(state, "observatory"), do: SidebarWorkflow.observatory_visible?(state)
  defp sidebar_visible?(_state, _sidebar_id), do: false

  @spec ignored_sidebar_action(EditorState.t(), String.t(), String.t(), String.t()) ::
          EditorState.t()
  defp ignored_sidebar_action(state, sidebar_id, kind, action) do
    Minga.Log.warning(
      :editor,
      "Ignored sidebar action id=#{inspect(sidebar_id)} kind=#{inspect(kind)} action=#{inspect(action)}"
    )

    NoticeWorkflow.publish(
      state,
      "Unsupported sidebar action: #{kind}/#{action}"
    )
  end

  # ── Git commit helpers ──────────────────────────────────────────────

  # Commit shells out to `git commit`, so it runs off the editor's critical path
  # on the same serialized :git_worktree lane as stage/discard (#2357). The op
  # builds its own success and failure messages because the commit hash is only
  # known after the subprocess returns; git-root resolution runs inside the
  # offloaded work.
  @spec commit_from_gui(state(), String.t(), boolean()) :: state()
  defp commit_from_gui(state, message, amend?) do
    pending_msg = commit_pending_msg(amend?)

    git_action(state, pending_msg, :commit, pending_msg, message: message, amend?: amend?)
  end

  @spec commit_pending_msg(boolean()) :: String.t()
  defp commit_pending_msg(true), do: "Amending…"
  defp commit_pending_msg(false), do: "Committing…"

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
        NoticeWorkflow.publish(
          state,
          "No git diff entry for #{path}"
        )

      [_ | [_ | _]] ->
        NoticeWorkflow.publish(
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
    case SidebarWorkflow.git_status_panel(state) do
      nil -> []
      panel -> Map.get(panel, :entries) || []
    end
  end

  @spec execute_registered_command(state(), atom()) :: state()
  defp execute_registered_command(state, command) do
    ExtensionEventWorkflow.dispatch(state, {:editor_action, :execute_git_command, command})
  end

  @spec open_git_diff_for_path(state(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          state()
  defp open_git_diff_for_path(state, git_root, git_path, abs_path, current_content, opts) do
    arguments = {git_root, git_path, abs_path, current_content, opts}

    ExtensionEventWorkflow.dispatch(
      state,
      {:editor_action, :open_git_diff_for_path, arguments}
    )
  end

  @spec open_git_diff_for_entry(state(), String.t(), Git.StatusEntry.t()) :: state()
  defp open_git_diff_for_entry(state, git_root, %Git.StatusEntry{} = entry) do
    abs_path = git_status_abs_path(git_root, entry.path)
    git_path = Path.relative_to(abs_path, git_root)
    git_entry = %{entry | path: git_path}

    case git_diff_content(git_root, abs_path, git_entry) do
      {:ok, current_content} ->
        open_git_diff_for_path(state, git_root, git_path, abs_path, current_content,
          staged: entry.staged
        )

      {:error, message} ->
        NoticeWorkflow.publish(state, message)
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

  @spec git_status_abs_path(String.t(), String.t()) :: String.t()
  defp git_status_abs_path(git_root, path) do
    git_status_abs_path(git_root, path, Minga.Project.resolve_root())
  end

  @spec git_status_abs_path(String.t(), String.t(), String.t() | nil) :: String.t()
  defp git_status_abs_path(git_root, path, nil), do: Path.join(git_root, path)

  defp git_status_abs_path(git_root, path, project_root) do
    if String.starts_with?(Path.expand(project_root), Path.expand(git_root)) do
      Path.join(project_root, path)
    else
      Path.join(git_root, path)
    end
  end

  # ── Git action helper ──────────────────────────────────────────────

  # Repository discovery may call git, so it is itself a typed FIFO effect. Its
  # applied result admits the actual mutation to the resolved repository lane.
  @spec git_action(state(), String.t(), GitMutation.operation(), String.t(), keyword()) :: state()
  defp git_action(state, pending_msg, operation, success_msg, opts \\ [])

  defp git_action(state, pending_msg, operation, success_msg, opts)
       when is_binary(pending_msg) and is_binary(success_msg) do
    {resolver, resolver_input} =
      Process.get(
        @git_root_resolver_key,
        {GitRepositoryResolver, :current_project}
      )

    request_opts =
      opts
      |> Keyword.put(:pending_message, pending_msg)
      |> Keyword.put(:success_message, success_msg)
      |> Keyword.put(:resolver, resolver)
      |> Keyword.put(:resolver_input, resolver_input)

    resource =
      "git:" <>
        Atom.to_string(operation) <> ":" <> to_string(Keyword.get(opts, :path, "repository"))

    {operation_feedback, feedback_operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        git_operation_kind(operation),
        resource,
        pending_msg,
        replace?: false
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    schedule_git_action(state, operation, feedback_operation.id, request_opts)
  end

  @spec schedule_git_action(state(), GitMutation.operation(), Operation.id(), keyword()) ::
          state()
  defp schedule_git_action(%{effect_scheduler: nil} = state, _operation, operation_id, _opts) do
    %{
      state
      | feedback:
          Feedback.accept_operation_feedback(
            state.feedback,
            OperationFeedback.finish(
              state.feedback.operation_feedback,
              operation_id,
              :error,
              "Git scheduler unavailable"
            )
          )
    }
  end

  defp schedule_git_action(state, operation, operation_id, request_opts) do
    request =
      GitMutationAdmission.request(
        state.effect_scheduler,
        operation,
        operation_id,
        request_opts
      )

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} ->
        state

      {:error, reason} ->
        %{
          state
          | feedback:
              Feedback.accept_operation_feedback(
                state.feedback,
                OperationFeedback.finish(
                  state.feedback.operation_feedback,
                  operation_id,
                  :error,
                  git_admission_error_message(reason)
                )
              )
        }
    end
  end

  @spec git_operation_kind(GitMutation.operation()) :: Operation.kind()
  defp git_operation_kind(:stage), do: :git_stage
  defp git_operation_kind(:unstage), do: :git_unstage
  defp git_operation_kind(:discard), do: :git_discard
  defp git_operation_kind(:stage_all), do: :git_stage_all
  defp git_operation_kind(:unstage_all), do: :git_unstage_all
  defp git_operation_kind(:commit), do: :git_commit

  @spec git_admission_error_message(EffectScheduler.admission_error()) :: String.t()
  defp git_admission_error_message(:queue_full), do: "Git action queue is full"
  defp git_admission_error_message(:scheduler_full), do: "Git effect scheduler is full"
  defp git_admission_error_message(reason), do: "Git action not scheduled: #{reason}"

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
          MingaEditor.Shell.Traditional.ModalWorkflow.update_completion(state, fn _ -> updated end),
          updated
        )
    end
  end

  # ── File tree helpers ──────────────────────────────────────────────

  @spec open_dropped_directory(state(), String.t()) :: state()
  defp open_dropped_directory(state, dir_path) do
    case Minga.Project.Root.directory(dir_path) do
      {:ok, root} -> activate_dropped_directory(state, root)
      {:error, _reason} -> state
    end
  end

  @spec activate_dropped_directory(state(), Minga.Project.Root.t()) :: state()
  defp activate_dropped_directory(state, root) do
    case Minga.Project.activate(Minga.Project, root) do
      {:ok, %Minga.Project.WorkspaceSnapshot{root: installed_root}} ->
        state
        |> FileTreeFreshness.update_project_root(installed_root.path)
        |> PickerUI.open(MingaEditor.UI.Picker.FileSource, %{project_root: installed_root})

      {:error, _reason} ->
        state
    end
  end

  # Moves the tree cursor to a specific index (used by GUI context menu / header actions).
  @spec move_tree_cursor(state(), non_neg_integer()) :: state()
  defp move_tree_cursor(state, index) do
    case state.workspace.file_tree.tree do
      nil ->
        state

      tree ->
        %{
          state
          | workspace:
              State.set_file_tree(
                state.workspace,
                (fn file_tree ->
                   FileTreeState.set_tree(file_tree, FileTree.select(tree, index))
                 end).(state.workspace.file_tree)
              )
        }
    end
  end

  # Moves the file tree cursor to the given index and performs the action.
  @spec gui_tree_action(state(), non_neg_integer(), :click | :toggle) :: state()
  defp gui_tree_action(state, index, action) do
    if state.workspace.file_tree.tree == nil do
      state
    else
      do_gui_tree_action(state, index, action)
    end
  end

  @spec do_gui_tree_action(state(), non_neg_integer(), :click | :toggle) :: state()
  defp do_gui_tree_action(state, index, action) do
    state = move_tree_cursor(state, index)

    case action do
      :click -> Commands.FileTree.open_or_toggle(state)
      :toggle -> Commands.FileTree.open_or_toggle(state)
    end
  end

  @spec open_file_tree_entry_in_split(state(), non_neg_integer()) :: state()
  defp open_file_tree_entry_in_split(state, index) do
    if state.workspace.file_tree.tree == nil do
      state
    else
      do_open_file_tree_entry_in_split(state, index)
    end
  end

  @spec do_open_file_tree_entry_in_split(state(), non_neg_integer()) :: state()
  defp do_open_file_tree_entry_in_split(state, index) do
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
    file_tree = MingaEditor.State.FileTree.unfocus(state.workspace.file_tree)

    workspace =
      state.workspace
      |> State.set_file_tree(file_tree)
      |> State.set_keymap_scope(:editor)

    %{state | workspace: workspace}
  end

  # ── Hover open action ──────────────────────────────────────────────

  @spec accept_hover_open_action(state()) :: state()
  defp accept_hover_open_action(state) do
    case state.shell_runtime.state.hover_popup do
      %MingaEditor.HoverPopup{open_action: action} when action != nil ->
        state = MingaEditor.Shell.Traditional.HoverPopupWorkflow.dismiss(state)
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

  @spec handle_shell_gui_action(EditorState.t(), term()) :: EditorState.t()
  defp handle_shell_gui_action(state, action) do
    state = MingaEditor.Shell.Workflow.ensure_available(state)

    {runtime, workspace} =
      MingaEditor.Shell.Runtime.route_gui_action(
        state.shell_runtime,
        state.workspace,
        action
      )

    %{state | shell_runtime: runtime, workspace: workspace}
  end

  # ── Tab helpers ───────────────────────────────────────────────────

  @spec reorder_tab(state(), Tab.id(), non_neg_integer()) :: state()
  defp reorder_tab(state, id, new_index) do
    update_tab_bar(state, &TabBar.reorder_tab(&1, id, new_index))
  end

  @spec update_tab_bar(state(), (TabBar.t() -> TabBar.t())) :: state()
  defp update_tab_bar(state, fun) when is_function(fun, 1) do
    state = MingaEditor.Shell.Workflow.ensure_available(state)

    case state.shell_runtime.state.tab_bar do
      %TabBar{} = tb ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(state.shell_runtime),
            fun.(tb)
          )

        %{
          state
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(
                state.shell_runtime,
                shell_state
              )
        }

      nil ->
        state
    end
  end

  # ── Tab path helpers ───────────────────────────────────────────────

  @spec copy_tab_path(state(), Tab.id()) :: state()
  defp copy_tab_path(state, id) do
    state = MingaEditor.Shell.Workflow.ensure_available(state)

    case tab_file_path(state, id) do
      nil ->
        NoticeWorkflow.publish(state, "Tab has no file path")

      path ->
        Clipboard.write_async(path)
        maybe_send_gui_clipboard_write(state, path)
        NoticeWorkflow.publish(state, "Copied #{path}")
    end
  end

  @spec maybe_send_gui_clipboard_write(state(), String.t()) :: :ok
  defp maybe_send_gui_clipboard_write(%{frontend: %{port_manager: nil}}, _path), do: :ok

  defp maybe_send_gui_clipboard_write(state, path) do
    MingaEditor.Frontend.clipboard_write(state.frontend.port_manager, path)
  end

  @spec tab_file_path(state(), Tab.id()) :: String.t() | nil
  defp tab_file_path(state, id) do
    state = MingaEditor.Shell.Workflow.ensure_available(state)

    case state.shell_runtime.state.tab_bar do
      %TabBar{} = tb -> tab_file_path_from_tab(state, tb, TabBar.get(tb, id))
      nil -> nil
    end
  end

  @spec tab_file_path_from_tab(state(), TabBar.t(), Tab.t() | nil) :: String.t() | nil
  defp tab_file_path_from_tab(_state, _tb, nil), do: nil
  defp tab_file_path_from_tab(_state, _tb, %Tab{kind: :agent}), do: nil

  defp tab_file_path_from_tab(state, %TabBar{active_id: active_id} = tb, %Tab{id: id}) do
    if id == active_id do
      active_buffer_path(state)
    else
      inactive_tab_path(TabBar.get(tb, id))
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
      case state.shell_runtime.state.tab_bar do
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

  # ── Volume unmount helpers ─────────────────────────────────────────

  # A volume is about to unmount. Protect any open buffers living under that
  # mount point: best-effort save dirty buffers so unsaved work is not lost,
  # then mark every affected buffer read-only so later edits and writes to the
  # now-stale path are rejected instead of failing silently.
  @spec handle_volume_will_unmount(state(), String.t()) :: state()
  defp handle_volume_will_unmount(state, volume_path) do
    prefix = normalize_volume_prefix(volume_path)

    case buffers_under_prefix(prefix) do
      [] ->
        Minga.Log.info(:editor, "Volume will unmount (#{volume_path}); no open buffers affected")
        state

      pids ->
        saved = save_and_disconnect_buffers(pids)

        Minga.Log.info(
          :editor,
          "Volume will unmount (#{volume_path}); disconnected #{Enum.count(pids)} buffer(s), saved #{saved}"
        )

        NoticeWorkflow.publish(
          state,
          "Volume unmounted: saved #{saved} and disconnected #{Enum.count(pids)} buffer(s) under #{volume_path}"
        )
    end
  end

  # Mount paths arrive without a trailing slash (e.g. "/Volumes/USB"). Append one
  # so prefix matching does not treat "/Volumes/USB2" as living under "/Volumes/USB".
  @spec normalize_volume_prefix(String.t()) :: String.t()
  defp normalize_volume_prefix(volume_path) do
    expanded = Path.expand(volume_path)
    if String.ends_with?(expanded, "/"), do: expanded, else: expanded <> "/"
  end

  # All live, file-backed buffer pids whose absolute path lives under the prefix.
  @spec buffers_under_prefix(String.t()) :: [pid()]
  defp buffers_under_prefix(prefix) do
    Minga.Buffer.Registry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.filter(&buffer_under_prefix?(&1, prefix))
  end

  @spec buffer_under_prefix?(pid(), String.t()) :: boolean()
  defp buffer_under_prefix?(pid, prefix) do
    Process.alive?(pid) and
      Buffer.buffer_type(pid) == :file and
      case Buffer.file_path(pid) do
        path when is_binary(path) -> String.starts_with?(path, prefix)
        _ -> false
      end
  catch
    :exit, _ -> false
  end

  # Best-effort save each dirty buffer, then mark every buffer read-only so the
  # stale path can no longer be written. Returns the count of buffers saved.
  @spec save_and_disconnect_buffers([pid()]) :: non_neg_integer()
  defp save_and_disconnect_buffers(pids) do
    Enum.reduce(pids, 0, fn pid, saved -> save_and_disconnect_buffer(pid, saved) end)
  end

  @spec save_and_disconnect_buffer(pid(), non_neg_integer()) :: non_neg_integer()
  defp save_and_disconnect_buffer(pid, saved) do
    saved = if Buffer.dirty?(pid) and Buffer.save(pid) == :ok, do: saved + 1, else: saved
    Buffer.set_read_only(pid, true)
    saved
  catch
    :exit, _ -> saved
  end

  # ── Git repo helpers ───────────────────────────────────────────────

  @spec refresh_current_git_repo() :: :ok
  defp refresh_current_git_repo do
    case MingaEditor.resolve_git_root() do
      nil -> :ok
      git_root -> MingaEditor.refresh_git_repo(git_root)
    end
  end

  # ── Window helpers ─────────────────────────────────────────────────

  # Commits a scroll-to-line viewport for the thumb-drag/track-click path (#2665),
  # echo-marking the committed top and recording a free-scroll event so the move is
  # treated exactly like a wheel/trackpad free-scroll (no `scroll_seq` bump, no cursor
  # re-anchor). When the window has a live buffer the cursor position feeds
  # `record_scroll_event/3`; without one there is nothing to detach from, so only the
  # echo mark is recorded.
  @spec scroll_to_line_commit(Window.t(), Viewport.t()) :: Window.t()
  defp scroll_to_line_commit(%Window{content: {:buffer, buf}} = window, new_vp)
       when is_pid(buf) do
    now = System.monotonic_time(:millisecond)
    cursor_pos = Buffer.cursor(buf)

    window
    |> Window.set_viewport(new_vp)
    |> Window.mark_scroll_echo(new_vp.top)
    |> Window.record_scroll_event(now, cursor_pos)
  end

  defp scroll_to_line_commit(%Window{} = window, new_vp) do
    window
    |> Window.set_viewport(new_vp)
    |> Window.mark_scroll_echo(new_vp.top)
  end

  @spec open_file_by_path_in_active_window(state(), String.t()) :: state()
  defp open_file_by_path_in_active_window(state, abs_path) do
    case BufferRegistry.file_tab_for_path_in_active_workspace(state, abs_path) do
      %Tab{} = tab ->
        open_tab_buffer_in_active_window(state, tab, abs_path)

      nil ->
        case Commands.start_buffer(abs_path, state.interaction.options_server) do
          {:ok, pid} ->
            register_buffer_in_active_window(state, pid, abs_path)

          {:error, :binary_file} ->
            NoticeWorkflow.publish(
              state,
              "Cannot open binary file: #{Path.basename(abs_path)}"
            )

          {:error, _reason} ->
            NoticeWorkflow.publish(
              state,
              "Could not open #{abs_path}"
            )
        end
    end
  end

  @spec open_tab_buffer_in_active_window(state(), Tab.t(), String.t()) :: state()
  defp open_tab_buffer_in_active_window(state, tab, abs_path) do
    case tab_active_buffer(tab) do
      pid when is_pid(pid) ->
        show_buffer_in_active_window(state, pid)

      nil ->
        NoticeWorkflow.publish(state, "Could not open #{abs_path}")
    end
  end

  @spec show_buffer_in_active_window(state(), pid()) :: state()
  defp show_buffer_in_active_window(state, pid) when is_pid(pid) do
    buffers =
      case Enum.find_index(state.workspace.buffers.list, &(&1 == pid)) do
        nil -> Buffers.add(state.workspace.buffers, pid)
        idx -> Buffers.switch_to(state.workspace.buffers, idx)
      end

    MingaEditor.BufferActivation.activate(state, buffers, notify_shell?: false)
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
    buffers = Buffers.add(state.workspace.buffers, buffer_pid)

    state =
      state
      |> MingaEditor.BufferActivation.activate(buffers, notify_shell?: false)
      |> MingaEditor.Handlers.BufferRegistry.monitor_buffer(buffer_pid)

    Minga.Log.info(:editor, "Opened: #{file_path}")

    Minga.Events.broadcast(
      :buffer_opened,
      %Minga.Events.BufferEvent{buffer: buffer_pid, path: file_path},
      state.extension_surfaces.events_registry
    )

    state = HighlightSync.setup_for_buffer_pid(state, buffer_pid)

    if state.frontend.backend != :headless do
      Process.send_after(self(), :request_code_lens_and_inlay_hints, 800)
    end

    state
  end

  # ── Vim mode state helper ──────────────────────────────────────────

  @spec set_vim_mode_state(state(), term()) :: state()
  defp set_vim_mode_state(state, new_ms) do
    %{
      state
      | workspace:
          State.set_editing(
            state.workspace,
            (&VimState.set_mode_state(&1, new_ms)).(state.workspace.editing)
          )
    }
  end

  @spec normalize_command_result(state() | {state(), term()}) :: state()
  defp normalize_command_result({new_state, _action}), do: new_state
  defp normalize_command_result(new_state), do: new_state

  # Dismisses whichever float popup source is live (#2338), mirroring the two
  # sources FloatPopupBuilder reads. Observatory inspection takes precedence
  # (the builder checks it first); otherwise close the :float popup window via
  # the popup lifecycle. Returns state unchanged when neither is present.
  @spec dismiss_float_popup(state()) :: state()
  defp dismiss_float_popup(state) do
    case SidebarWorkflow.observatory(state) do
      %ObservatoryState{} = observatory ->
        dismiss_float_popup(state, ObservatoryState.inspection(observatory))

      nil ->
        dismiss_window_popup(state)
    end
  end

  @spec dismiss_float_popup(state(), MingaEditor.Observatory.Inspection.t() | nil) :: state()
  defp dismiss_float_popup(state, %{visible: true}), do: Observatory.inspect_process(state, "")
  defp dismiss_float_popup(state, _inspection), do: dismiss_window_popup(state)

  @spec dismiss_window_popup(state()) :: state()
  defp dismiss_window_popup(state) do
    case find_float_popup_window_id(state) do
      nil -> state
      window_id -> PopupLifecycle.close_popup(state, window_id)
    end
  end

  @spec find_float_popup_window_id(state()) :: Window.id() | nil
  defp find_float_popup_window_id(%{workspace: %{windows: %{map: map}}}) when is_map(map) do
    Enum.find_value(map, fn
      {id,
       %{
         popup_meta: %MingaEditor.UI.Popup.Active{
           rule: %Minga.Popup.Rule{display: :float}
         }
       }} ->
        id

      _ ->
        nil
    end)
  end

  defp find_float_popup_window_id(_state), do: nil

  @spec route_panel_action_to_extension(state(), String.t(), atom() | String.t(), map()) ::
          state()
  defp route_panel_action_to_extension(state, ext_name, action_name, context) do
    case SemanticUIRegistry.dispatch_panel_action(state, ext_name, action_name, context) do
      {:ok, state} -> state
      :error -> route_legacy_panel_action_to_extension(state, ext_name, action_name, context)
    end
  end

  @spec route_legacy_panel_action_to_extension(state(), String.t(), atom() | String.t(), map()) ::
          state()
  defp route_legacy_panel_action_to_extension(state, ext_name, action_name, context) do
    ext_atom = String.to_existing_atom(ext_name)
    action_atom = legacy_panel_action_name(action_name)

    case Minga.Extension.Registry.get(Minga.Extension.Registry, ext_atom) do
      {:ok, %{pid: pid}} when is_pid(pid) ->
        send(pid, {:panel_action, action_atom, context})
        state

      _ ->
        extension_panel_action_unavailable(state, ext_name, action_name)
    end
  rescue
    ArgumentError -> extension_panel_action_unavailable(state, ext_name, action_name)
  end

  @spec legacy_panel_action_name(atom() | String.t()) :: atom()
  defp legacy_panel_action_name(action_name) when is_atom(action_name), do: action_name

  defp legacy_panel_action_name(action_name) when is_binary(action_name),
    do: String.to_existing_atom(action_name)

  @spec extension_panel_action_unavailable(state(), String.t(), atom() | String.t()) :: state()
  defp extension_panel_action_unavailable(state, ext_name, action_name) do
    Minga.Log.warning(
      :editor,
      "Extension panel action ignored: #{ext_name}/#{action_name} unavailable"
    )

    NoticeWorkflow.publish(
      state,
      "Extension panel action unavailable"
    )
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
    whole_word = Keyword.get(opts, :whole_word, false)

    if use_regex or case_insensitive or whole_word do
      line = content |> :binary.split("\n", [:global]) |> Enum.at(match_line)
      searchable = binary_part(line, match_col, byte_size(line) - match_col)
      regex_match_len(pattern, searchable, use_regex, case_insensitive, whole_word)
    else
      byte_size(pattern)
    end
  end

  @spec regex_match_len(String.t(), String.t(), boolean(), boolean(), boolean()) ::
          non_neg_integer()
  defp regex_match_len(pattern, searchable, use_regex, case_insensitive, whole_word) do
    regex_source = if use_regex, do: pattern, else: Regex.escape(pattern)
    regex_source = if whole_word, do: "\\b#{regex_source}\\b", else: regex_source
    regex_opts = if case_insensitive, do: "i", else: ""

    with {:ok, regex} <- Regex.compile(regex_source, regex_opts),
         [{0, len}] <- Regex.run(regex, searchable, return: :index, capture: :first) do
      len
    else
      _ -> byte_size(pattern)
    end
  end
end
