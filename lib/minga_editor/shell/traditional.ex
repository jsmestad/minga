defmodule MingaEditor.Shell.Traditional do
  @moduledoc """
  Traditional tab-based editor shell.

  The default presentation shell: tab bar, file tree sidebar, split
  windows, modeline, picker, agent panel, and which-key popup. This is
  the UX that ships today.

  Presentation fields live in `MingaEditor.Shell.Traditional.State`. The
  Editor GenServer stores this as `state.shell_state` and dispatches
  presentation events through the `MingaEditor.Shell` behaviour callbacks.

  ## Migration status

  Fields are being migrated from `MingaEditor.State` into
  `Shell.Traditional.State` in batches. See `BIG_REFACTOR_PLAN.md`
  Phase F for the full plan.

  Batch 1 (current): `nav_flash`, `hover_popup`, `dashboard`, `status_msg`

  ## Rendering architecture

  Layout, chrome, and rendering are owned by modules under
  `Shell.Traditional.*`: `Layout`, `Chrome`, and `Renderer`. These
  currently delegate to `Editor.*` modules; the implementations will
  move here as the shell independence refactor progresses.
  """

  @behaviour MingaEditor.Shell
  @behaviour MingaEditor.Shell.Layout
  @behaviour MingaEditor.Shell.Chrome
  @behaviour MingaEditor.Shell.InputRouter
  @behaviour MingaEditor.Shell.BufferLifecycle
  @behaviour MingaEditor.Shell.TabQueries

  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias MingaEditor.Agent.UIState
  alias Minga.Buffer
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Window.Content
  alias Minga.Log
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.Workspace.State, as: WorkspaceState

  @impl true
  @spec init(keyword()) :: MingaEditor.Shell.shell_state()
  def init(_opts) do
    %ShellState{}
  end

  @impl true
  @spec handle_event(ShellState.t(), MingaEditor.Workspace.State.t(), term()) ::
          {ShellState.t(), MingaEditor.Workspace.State.t()}
  def handle_event(%ShellState{} = shell_state, workspace, {:git_status_changed, entries}) do
    {ShellState.refresh_git_status_tui_state(shell_state, entries), workspace}
  end

  def handle_event(%ShellState{tab_bar: nil} = shell_state, workspace, _event) do
    {shell_state, workspace}
  end

  def handle_event(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        {:background_subagent_started, %MingaAgent.Subagent.Handle{} = handle}
      ) do
    if TabBar.find_by_session(tb, handle.pid) do
      {shell_state, workspace}
    else
      label = MingaAgent.Subagent.Handle.label(handle)
      {tb, tab} = TabBar.insert(tb, :agent, label)

      tab =
        tab
        |> Tab.set_session(handle.pid)
        |> Tab.set_agent_status(:thinking)
        |> Tab.mark_background_subagent(handle)

      tb = TabBar.update_tab(tb, tab.id, fn _ -> tab end)
      context = background_agent_context(workspace)
      tb = TabBar.update_context(tb, tab.id, context)
      {%{shell_state | tab_bar: tb}, workspace}
    end
  end

  def handle_event(shell_state, workspace, _event) do
    {shell_state, workspace}
  end

  @impl true
  @spec handle_gui_action(ShellState.t(), MingaEditor.Workspace.State.t(), term()) ::
          {ShellState.t(), MingaEditor.Workspace.State.t()}

  # No tab bar yet (GUI not initialized): close_tab is a no-op.
  def handle_gui_action(%ShellState{tab_bar: nil} = shell_state, workspace, {:close_tab, _id}) do
    {shell_state, workspace}
  end

  # Switch to the target tab if not already active. The actual buffer
  # close is handled by the Editor after this returns.
  def handle_gui_action(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        {:close_tab, id}
      ) do
    if tb.active_id != id do
      switch_to_buffer_tab(shell_state, workspace, id)
    else
      {shell_state, workspace}
    end
  end

  def handle_gui_action(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        {:workspace_close, ws_id}
      ) do
    {%{shell_state | tab_bar: TabBar.remove_workspace(tb, ws_id)}, workspace}
  end

  def handle_gui_action(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        {:workspace_rename, ws_id, name}
      ) do
    tb = TabBar.update_workspace(tb, ws_id, &Workspace.rename(&1, name))
    {%{shell_state | tab_bar: tb}, workspace}
  end

  def handle_gui_action(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        {:workspace_set_icon, ws_id, icon}
      ) do
    tb = TabBar.update_workspace(tb, ws_id, &Workspace.set_icon(&1, icon))
    {%{shell_state | tab_bar: tb}, workspace}
  end

  def handle_gui_action(shell_state, workspace, _action) do
    {shell_state, workspace}
  end

  @impl true
  @spec compute_layout(term()) :: MingaEditor.Layout.t()
  defdelegate compute_layout(editor_state), to: MingaEditor.Shell.Traditional.Layout, as: :compute

  @impl true
  @spec build_chrome(term(), MingaEditor.Layout.t(), map(), term()) ::
          MingaEditor.RenderPipeline.Chrome.t()
  defdelegate build_chrome(editor_state, layout, scrolls, cursor_info),
    to: MingaEditor.Shell.Traditional.Chrome

  @impl true
  @spec chrome_fingerprint(term()) :: term()
  defdelegate chrome_fingerprint(editor_state), to: MingaEditor.Shell.Traditional.Chrome

  @impl true
  @spec async_render?(term()) :: boolean()
  def async_render?(%{shell: __MODULE__, workspace: %{buffers: %{active: active}}})
      when is_pid(active),
      do: true

  def async_render?(%{shell: __MODULE__}), do: false

  @impl true
  @spec render(term()) :: term()
  defdelegate render(editor_state), to: MingaEditor.Shell.Traditional.Renderer

  @impl true
  @spec input_handlers(term()) :: %{overlay: [module()], surface: [module()]}
  def input_handlers(editor_state) do
    %{
      overlay: MingaEditor.Input.overlay_handlers(),
      surface: MingaEditor.Input.surface_handlers(editor_state)
    }
  end

  # -------------------------------------------------------------------
  # Buffer lifecycle callbacks
  # -------------------------------------------------------------------

  @impl true
  @spec on_buffer_added(
          ShellState.t(),
          WorkspaceState.t(),
          WorkspaceState.t(),
          pid(),
          atom()
        ) :: {ShellState.t(), WorkspaceState.t(), [MingaEditor.effect()]}
  def on_buffer_added(shell_state, prev_workspace, workspace, buffer_pid, context) do
    do_on_buffer_added(
      maybe_dismiss_dashboard(shell_state),
      prev_workspace,
      workspace,
      buffer_pid,
      context
    )
  end

  @spec on_buffer_added(ShellState.t(), WorkspaceState.t(), pid(), atom()) ::
          {ShellState.t(), WorkspaceState.t(), [MingaEditor.effect()]}
  def on_buffer_added(shell_state, workspace, buffer_pid, context \\ :open) do
    on_buffer_added(shell_state, workspace, workspace, buffer_pid, context)
  end

  # Dismisses the dashboard modal when a buffer becomes active. The
  # dashboard is the "no buffer" splash; once a buffer opens, the
  # splash should disappear so it does not stick visually behind the
  # buffer view. Other modal variants are left alone.
  @spec maybe_dismiss_dashboard(ShellState.t()) :: ShellState.t()
  defp maybe_dismiss_dashboard(%ShellState{modal: {:dashboard, _}} = shell_state),
    do: ShellState.set_modal(shell_state, :none)

  defp maybe_dismiss_dashboard(shell_state), do: shell_state

  @spec do_on_buffer_added(
          ShellState.t(),
          WorkspaceState.t(),
          WorkspaceState.t(),
          pid(),
          atom()
        ) :: {ShellState.t(), WorkspaceState.t(), [MingaEditor.effect()]}
  defp do_on_buffer_added(
         %ShellState{tab_bar: nil} = shell_state,
         _prev_workspace,
         workspace,
         _buffer_pid,
         _context
       ) do
    workspace = WorkspaceState.sync_active_window_buffer(workspace)
    {shell_state, workspace, []}
  end

  defp do_on_buffer_added(
         %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
         prev_workspace,
         workspace,
         buffer_pid,
         context
       ) do
    label = buffer_label(buffer_pid)

    Log.debug(:editor, fn ->
      "[tab] on_buffer_added label=#{label} context=#{context} tab=#{tb.active_id}"
    end)

    case find_tab_for_buffer(tb, buffer_pid) do
      %Tab{id: tab_id} ->
        switch_to_buffer_tab(shell_state, prev_workspace, workspace, tab_id)

      nil ->
        case {context, TabBar.active(tb).kind} do
          {:preview, _} ->
            # Preview: sync window content only, leave tab bar unchanged.
            # The tab label stays as-is so confirm can detect "no tab for
            # this buffer" and create a new one.
            workspace = WorkspaceState.sync_active_window_buffer(workspace)
            {shell_state, workspace, []}

          {_, :agent} ->
            open_buffer_from_agent_tab(shell_state, prev_workspace, workspace, label)

          {_, :file} ->
            open_buffer_in_file_tab(shell_state, prev_workspace, workspace, label)
        end
    end
  end

  @impl true
  @spec on_buffer_switched(ShellState.t(), WorkspaceState.t()) ::
          {ShellState.t(), WorkspaceState.t(), [MingaEditor.effect()]}
  def on_buffer_switched(%ShellState{tab_bar: nil} = shell_state, workspace) do
    {shell_state, workspace, []}
  end

  def on_buffer_switched(%ShellState{tab_bar: %TabBar{} = tb} = shell_state, workspace) do
    case TabBar.active(tb) do
      %Tab{kind: :file} ->
        label = buffer_label(workspace.buffers.active)
        tb = TabBar.update_label(tb, tb.active_id, label)
        tb = TabBar.update_context(tb, tb.active_id, WorkspaceState.to_tab_context(workspace))
        {%{shell_state | tab_bar: tb}, workspace, []}

      %Tab{} ->
        tb = TabBar.update_context(tb, tb.active_id, WorkspaceState.to_tab_context(workspace))
        {%{shell_state | tab_bar: tb}, workspace, []}

      nil ->
        {shell_state, workspace, []}
    end
  end

  @impl true
  @spec on_buffer_died(ShellState.t(), WorkspaceState.t(), pid()) ::
          {ShellState.t(), WorkspaceState.t(), [MingaEditor.effect()]}
  def on_buffer_died(shell_state, workspace, _dead_pid) do
    workspace = WorkspaceState.sync_active_window_buffer(workspace)
    {shell_state, workspace, []}
  end

  # -------------------------------------------------------------------
  # Agent event callbacks
  # -------------------------------------------------------------------

  @impl true
  @spec on_agent_event(ShellState.t(), WorkspaceState.t(), pid(), term()) ::
          {ShellState.t(), WorkspaceState.t(), [MingaEditor.effect()]}
  def on_agent_event(%ShellState{tab_bar: nil} = shell_state, workspace, _session_pid, _event) do
    {shell_state, workspace, []}
  end

  def on_agent_event(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        session_pid,
        {:status_changed, status}
      ) do
    # Update the tab's agent status badge
    tb =
      case TabBar.find_by_session(tb, session_pid) do
        %Tab{id: id} -> TabBar.update_tab(tb, id, &Tab.set_agent_status(&1, status))
        nil -> tb
      end

    # Set attention flag when agent needs user input
    tb =
      if status in [:idle, :error] do
        TabBar.set_attention_by_session(tb, session_pid, true)
      else
        tb
      end

    {%{shell_state | tab_bar: tb}, workspace, []}
  end

  def on_agent_event(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        session_pid,
        {:approval_pending, _}
      ) do
    tb = TabBar.set_attention_by_session(tb, session_pid, true)
    {%{shell_state | tab_bar: tb}, workspace, []}
  end

  # A direct :error event raises attention so a background tab whose session
  # crashes mid-stream still surfaces in the tab bar (the broader status_changed
  # path also raises attention on :error, but a session can emit :error without
  # a preceding :status_changed transition).
  def on_agent_event(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        session_pid,
        {:error, _message}
      ) do
    tb = TabBar.set_attention_by_session(tb, session_pid, true)
    {%{shell_state | tab_bar: tb}, workspace, []}
  end

  def on_agent_event(shell_state, workspace, _session_pid, _event) do
    {shell_state, workspace, []}
  end

  # -------------------------------------------------------------------
  # Tab query/mutation delegates
  # -------------------------------------------------------------------

  @impl true
  @spec active_tab(ShellState.t()) :: Tab.t() | nil
  def active_tab(%ShellState{tab_bar: nil}), do: nil
  def active_tab(%ShellState{tab_bar: tb}), do: TabBar.active(tb)

  @impl true
  @spec find_tab_by_buffer(ShellState.t(), pid()) :: Tab.t() | nil
  def find_tab_by_buffer(%ShellState{tab_bar: nil}, _pid), do: nil

  def find_tab_by_buffer(%ShellState{tab_bar: tb}, pid) do
    Enum.find(tb.tabs, fn tab ->
      tab.kind == :file and tab_has_active_buffer?(tab, pid)
    end)
  end

  @impl true
  @spec active_tab_kind(ShellState.t()) :: atom()
  def active_tab_kind(%ShellState{tab_bar: nil}), do: :file

  def active_tab_kind(%ShellState{tab_bar: tb}) do
    %Tab{kind: kind} = TabBar.active(tb)
    kind
  end

  @impl true
  @spec set_tab_session(ShellState.t(), Tab.id(), pid() | nil) :: ShellState.t()
  def set_tab_session(%ShellState{tab_bar: nil} = shell_state, _tab_id, _session_pid) do
    shell_state
  end

  def set_tab_session(%ShellState{tab_bar: tb} = shell_state, tab_id, session_pid) do
    %{shell_state | tab_bar: TabBar.update_tab(tb, tab_id, &Tab.set_session(&1, session_pid))}
  end

  @impl true
  @spec active_session(ShellState.t()) :: pid() | nil
  def active_session(%ShellState{tab_bar: nil}), do: nil

  def active_session(%ShellState{tab_bar: tb}) do
    case TabBar.active(tb) do
      %Tab{session: pid} -> pid
      _ -> nil
    end
  end

  # -------------------------------------------------------------------
  # Buffer lifecycle helpers
  # -------------------------------------------------------------------

  @spec background_agent_context(WorkspaceState.t()) :: Tab.context()
  defp background_agent_context(workspace) do
    agent_buf = AgentBufferSync.start_buffer()
    rows = max(workspace.viewport.rows, 1)
    cols = max(workspace.viewport.cols, 1)

    workspace
    |> WorkspaceState.to_tab_context()
    |> TabContext.put_fields(%{
      keymap_scope: :agent,
      agent_ui: UIState.new(),
      buffers: background_agent_buffers(agent_buf),
      windows: background_agent_windows(agent_buf, rows, cols)
    })
  end

  @spec background_agent_buffers(pid() | nil) :: Buffers.t()
  defp background_agent_buffers(agent_buf) when is_pid(agent_buf) do
    %Buffers{active: agent_buf, list: [agent_buf], active_index: 0}
  end

  defp background_agent_buffers(_agent_buf), do: %Buffers{}

  @spec background_agent_windows(pid() | nil, pos_integer(), pos_integer()) :: Windows.t()
  defp background_agent_windows(agent_buf, rows, cols) when is_pid(agent_buf) do
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, agent_buf, rows, cols)

    %Windows{
      tree: WindowTree.new(win_id),
      map: %{win_id => agent_window},
      active: win_id,
      next_id: win_id + 1
    }
  end

  defp background_agent_windows(_agent_buf, _rows, _cols), do: %Windows{}

  @spec find_tab_for_buffer(TabBar.t(), pid()) :: Tab.t() | nil
  defp find_tab_for_buffer(%TabBar{tabs: tabs}, pid) when is_pid(pid) do
    Enum.find(tabs, fn tab ->
      tab.kind == :file and tab_has_active_buffer?(tab, pid)
    end)
  end

  # Switch to an existing file tab that matches the buffer being opened.
  @spec switch_to_buffer_tab(ShellState.t(), WorkspaceState.t(), Tab.id()) ::
          {ShellState.t(), WorkspaceState.t(), [MingaEditor.effect()]}
  defp switch_to_buffer_tab(shell_state, workspace, target_id) do
    switch_to_buffer_tab(shell_state, workspace, workspace, target_id)
  end

  @spec switch_to_buffer_tab(ShellState.t(), WorkspaceState.t(), WorkspaceState.t(), Tab.id()) ::
          {ShellState.t(), WorkspaceState.t(), [MingaEditor.effect()]}
  defp switch_to_buffer_tab(
         %ShellState{tab_bar: tb} = shell_state,
         prev_workspace,
         workspace,
         target_id
       ) do
    current_id = tb.active_id

    if current_id == target_id do
      {shell_state, workspace, []}
    else
      # Snapshot the outgoing tab before the buffer-pool mutation that triggered this switch.
      context = WorkspaceState.to_tab_context(prev_workspace)
      tb = TabBar.update_context(tb, current_id, context)

      # Switch pointer and restore target tab's workspace
      tb = TabBar.switch_to(tb, target_id)
      target = TabBar.active(tb)
      workspace = WorkspaceState.restore_tab_context(workspace, target.context)

      # Clear attention flag on the tab we're switching to
      tb = TabBar.update_tab(tb, target_id, &Tab.set_attention(&1, false))

      workspace = WorkspaceState.invalidate_all_windows(workspace)
      {%{shell_state | tab_bar: tb}, workspace, []}
    end
  end

  # Opens a file buffer when the active tab is an agent tab.
  # Creates a new file tab, resets agent UI state, and syncs the window.
  # Returns a :stop_spinner effect so the Editor cancels the outgoing
  # agent spinner timer when leaving the agent context.
  @spec open_buffer_from_agent_tab(
          ShellState.t(),
          WorkspaceState.t(),
          WorkspaceState.t(),
          String.t()
        ) :: {ShellState.t(), WorkspaceState.t(), [MingaEditor.effect()]}
  defp open_buffer_from_agent_tab(
         %ShellState{tab_bar: tb} = shell_state,
         prev_workspace,
         workspace,
         label
       ) do
    # Snapshot current agent tab before leaving
    context = WorkspaceState.to_tab_context(prev_workspace)
    tb = TabBar.update_context(tb, tb.active_id, context)

    # Create file tab (TabBar.add auto-activates it)
    {tb, new_tab} = TabBar.add(tb, :file, label)

    # Leave agent UI view: reset to editor scope and window content type
    workspace =
      workspace
      |> WorkspaceState.set_agent_ui(UIState.new())
      |> WorkspaceState.set_keymap_scope(:editor)

    workspace = reset_active_window_to_buffer(workspace)
    workspace = WorkspaceState.sync_active_window_buffer(workspace)

    # Snapshot the new tab's context
    new_context = WorkspaceState.to_tab_context(workspace)
    tb = TabBar.update_context(tb, new_tab.id, new_context)

    Log.debug(:editor, fn -> "[tab] on_buffer_added new tab=#{new_tab.id} label=#{label}" end)

    {%{shell_state | tab_bar: tb}, workspace, [:stop_spinner]}
  end

  # Opens a file buffer when the active tab is already a file tab.
  # Creates a new file tab and syncs the buffer into the window.
  # Used for permanent opens: file tree, `:e`, picker confirm, LSP jump.
  @spec open_buffer_in_file_tab(
          ShellState.t(),
          WorkspaceState.t(),
          WorkspaceState.t(),
          String.t()
        ) :: {ShellState.t(), WorkspaceState.t(), [MingaEditor.effect()]}
  defp open_buffer_in_file_tab(
         %ShellState{tab_bar: tb} = shell_state,
         prev_workspace,
         workspace,
         label
       ) do
    # Snapshot current tab before leaving
    context = WorkspaceState.to_tab_context(prev_workspace)
    tb = TabBar.update_context(tb, tb.active_id, context)

    # Create file tab (TabBar.add auto-activates it)
    {tb, new_tab} = TabBar.add(tb, :file, label)
    workspace = WorkspaceState.sync_active_window_buffer(workspace)

    # Snapshot the new tab's context
    new_context = WorkspaceState.to_tab_context(workspace)
    tb = TabBar.update_context(tb, new_tab.id, new_context)

    {%{shell_state | tab_bar: tb}, workspace, []}
  end

  # Resets the active window's content type from agent_chat back to buffer.
  @spec reset_active_window_to_buffer(WorkspaceState.t()) :: WorkspaceState.t()
  defp reset_active_window_to_buffer(workspace) do
    %{windows: windows, buffers: buffers} = workspace
    id = windows.active

    case Windows.fetch(windows, id) do
      {:ok, %Window{content: {:buffer, _}}} ->
        workspace

      {:ok, %Window{}} ->
        windows =
          Windows.update(windows, id, fn window ->
            %{
              Window.invalidate(window)
              | buffer: buffers.active,
                content: Content.buffer(buffers.active)
            }
          end)

        WorkspaceState.set_windows(workspace, windows)

      :error ->
        workspace
    end
  end

  @spec buffer_label(pid()) :: String.t()
  defp buffer_label(pid) when is_pid(pid) do
    case Buffer.buffer_name(pid) do
      nil ->
        case Buffer.file_path(pid) do
          nil -> "[no file]"
          path -> Path.basename(path)
        end

      name ->
        name
    end
  catch
    :exit, _ -> "[dead]"
  end

  defp buffer_label(_), do: "[unknown]"

  @spec tab_has_active_buffer?(Tab.t(), pid()) :: boolean()
  defp tab_has_active_buffer?(%Tab{context: context}, pid) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: ^pid}} -> true
      _ -> false
    end
  end
end
