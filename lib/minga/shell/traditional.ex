defmodule Minga.Shell.Traditional do
  @moduledoc """
  Traditional tab-based editor shell.

  The default presentation shell: tab bar, file tree sidebar, split
  windows, modeline, picker, agent panel, and which-key popup. This is
  the UX that ships today.

  Presentation fields live in `Minga.Shell.Traditional.State`. The
  Editor GenServer stores this as `state.shell_state` and dispatches
  presentation events through the `Minga.Shell` behaviour callbacks.

  ## Migration status

  Fields are being migrated from `Minga.Editor.State` into
  `Shell.Traditional.State` in batches. See `BIG_REFACTOR_PLAN.md`
  Phase F for the full plan.

  Batch 1 (current): `nav_flash`, `hover_popup`, `dashboard`, `status_msg`

  ## Rendering architecture

  Layout, chrome, and rendering are owned by modules under
  `Shell.Traditional.*`: `Layout`, `Chrome`, and `Renderer`. These
  currently delegate to `Editor.*` modules; the implementations will
  move here as the shell independence refactor progresses.
  """

  @behaviour Minga.Shell

  alias Minga.Agent.UIState
  alias Minga.Buffer
  alias Minga.Editor.State.AgentGroup
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Log
  alias Minga.Shell.Traditional.State, as: ShellState
  alias Minga.Workspace.State, as: WorkspaceState

  @impl true
  @spec init(keyword()) :: Minga.Shell.shell_state()
  def init(_opts) do
    %ShellState{}
  end

  @impl true
  @spec handle_event(ShellState.t(), Minga.Workspace.State.t(), term()) ::
          {ShellState.t(), Minga.Workspace.State.t()}
  def handle_event(shell_state, workspace, _event) do
    {shell_state, workspace}
  end

  @impl true
  @spec handle_gui_action(ShellState.t(), Minga.Workspace.State.t(), term()) ::
          {ShellState.t(), Minga.Workspace.State.t()}

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
        {:agent_group_close, ws_id}
      ) do
    {%{shell_state | tab_bar: TabBar.remove_group(tb, ws_id)}, workspace}
  end

  def handle_gui_action(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        {:agent_group_rename, ws_id, name}
      ) do
    tb = TabBar.update_group(tb, ws_id, &AgentGroup.rename(&1, name))
    {%{shell_state | tab_bar: tb}, workspace}
  end

  def handle_gui_action(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        {:agent_group_set_icon, ws_id, icon}
      ) do
    tb = TabBar.update_group(tb, ws_id, &AgentGroup.set_icon(&1, icon))
    {%{shell_state | tab_bar: tb}, workspace}
  end

  def handle_gui_action(shell_state, workspace, _action) do
    {shell_state, workspace}
  end

  @impl true
  @spec compute_layout(term()) :: Minga.Editor.Layout.t()
  defdelegate compute_layout(editor_state), to: Minga.Shell.Traditional.Layout, as: :compute

  @impl true
  @spec build_chrome(term(), Minga.Editor.Layout.t(), map(), term()) ::
          Minga.Editor.RenderPipeline.Chrome.t()
  defdelegate build_chrome(editor_state, layout, scrolls, cursor_info),
    to: Minga.Shell.Traditional.Chrome

  @impl true
  @spec render(term()) :: term()
  defdelegate render(editor_state), to: Minga.Shell.Traditional.Renderer

  @impl true
  @spec input_handlers(term()) :: %{overlay: [module()], surface: [module()]}
  def input_handlers(editor_state) do
    %{
      overlay: Minga.Input.overlay_handlers(),
      surface: Minga.Input.surface_handlers(editor_state)
    }
  end

  # -------------------------------------------------------------------
  # Buffer lifecycle callbacks
  # -------------------------------------------------------------------

  @impl true
  @spec on_buffer_added(ShellState.t(), WorkspaceState.t(), pid()) ::
          {ShellState.t(), WorkspaceState.t()}
  def on_buffer_added(%ShellState{tab_bar: nil} = shell_state, workspace, _buffer_pid) do
    workspace = WorkspaceState.sync_active_window_buffer(workspace)
    {shell_state, workspace}
  end

  def on_buffer_added(%ShellState{tab_bar: %TabBar{} = tb} = shell_state, workspace, buffer_pid) do
    label = buffer_label(buffer_pid)
    active_tab = TabBar.active(tb)

    Log.debug(:editor, fn ->
      "[tab] on_buffer_added label=#{label} tab=#{tb.active_id} kind=#{active_tab.kind}"
    end)

    case find_tab_for_buffer(tb, label) do
      %Tab{id: tab_id} ->
        switch_to_buffer_tab(shell_state, workspace, tab_id)

      nil ->
        case active_tab.kind do
          :agent ->
            open_buffer_from_agent_tab(shell_state, workspace, label)

          :file ->
            open_buffer_in_file_tab(shell_state, workspace, label)
        end
    end
  end

  @impl true
  @spec on_buffer_switched(ShellState.t(), WorkspaceState.t()) ::
          {ShellState.t(), WorkspaceState.t()}
  def on_buffer_switched(shell_state, workspace) do
    {shell_state, workspace}
  end

  @impl true
  @spec on_buffer_died(ShellState.t(), WorkspaceState.t(), pid()) ::
          {ShellState.t(), WorkspaceState.t()}
  def on_buffer_died(shell_state, workspace, _dead_pid) do
    {shell_state, workspace}
  end

  # -------------------------------------------------------------------
  # Agent event callbacks
  # -------------------------------------------------------------------

  @impl true
  @spec on_agent_event(ShellState.t(), WorkspaceState.t(), pid(), term()) ::
          {ShellState.t(), WorkspaceState.t()}
  def on_agent_event(%ShellState{tab_bar: nil} = shell_state, workspace, _session_pid, _event) do
    {shell_state, workspace}
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

    {%{shell_state | tab_bar: tb}, workspace}
  end

  def on_agent_event(
        %ShellState{tab_bar: %TabBar{} = tb} = shell_state,
        workspace,
        session_pid,
        {:approval_pending, _}
      ) do
    tb = TabBar.set_attention_by_session(tb, session_pid, true)
    {%{shell_state | tab_bar: tb}, workspace}
  end

  def on_agent_event(shell_state, workspace, _session_pid, _event) do
    {shell_state, workspace}
  end

  # -------------------------------------------------------------------
  # Buffer lifecycle helpers
  # -------------------------------------------------------------------

  @spec find_tab_for_buffer(TabBar.t(), String.t()) :: Tab.t() | nil
  defp find_tab_for_buffer(%TabBar{tabs: tabs}, label) do
    Enum.find(tabs, fn tab ->
      tab.kind == :file and tab.label == label
    end)
  end

  # Switch to an existing file tab that matches the buffer being opened.
  @spec switch_to_buffer_tab(ShellState.t(), WorkspaceState.t(), Tab.id()) ::
          {ShellState.t(), WorkspaceState.t()}
  defp switch_to_buffer_tab(%ShellState{tab_bar: tb} = shell_state, workspace, target_id) do
    current_id = tb.active_id

    if current_id == target_id do
      {shell_state, workspace}
    else
      # Snapshot current workspace onto outgoing tab
      context = Map.from_struct(workspace)
      tb = TabBar.update_context(tb, current_id, context)

      # Switch pointer and restore target tab's workspace
      tb = TabBar.switch_to(tb, target_id)
      target = TabBar.active(tb)
      workspace = restore_workspace(workspace, target.context)

      # Clear attention flag on the tab we're switching to
      tb = TabBar.update_tab(tb, target_id, &Tab.set_attention(&1, false))

      workspace = WorkspaceState.invalidate_all_windows(workspace)
      {%{shell_state | tab_bar: tb}, workspace}
    end
  end

  # Opens a file buffer when the active tab is an agent tab.
  # Creates a new file tab, resets agent UI state, and syncs the window.
  @spec open_buffer_from_agent_tab(ShellState.t(), WorkspaceState.t(), String.t()) ::
          {ShellState.t(), WorkspaceState.t()}
  defp open_buffer_from_agent_tab(%ShellState{tab_bar: tb} = shell_state, workspace, label) do
    # Snapshot current agent tab before leaving
    context = Map.from_struct(workspace)
    tb = TabBar.update_context(tb, tb.active_id, context)

    # Create file tab (TabBar.add auto-activates it)
    {tb, new_tab} = TabBar.add(tb, :file, label)

    # Leave agent UI view: reset to editor scope and window content type
    workspace = %{workspace | agent_ui: UIState.new(), keymap_scope: :editor}
    workspace = reset_active_window_to_buffer(workspace)
    workspace = WorkspaceState.sync_active_window_buffer(workspace)

    # Snapshot the new tab's context
    new_context = Map.from_struct(workspace)
    tb = TabBar.update_context(tb, new_tab.id, new_context)

    Log.debug(:editor, fn -> "[tab] on_buffer_added new tab=#{new_tab.id} label=#{label}" end)

    {%{shell_state | tab_bar: tb}, workspace}
  end

  # Opens a file buffer when the active tab is already a file tab.
  # Creates a new file tab and syncs the buffer into the window.
  @spec open_buffer_in_file_tab(ShellState.t(), WorkspaceState.t(), String.t()) ::
          {ShellState.t(), WorkspaceState.t()}
  defp open_buffer_in_file_tab(%ShellState{tab_bar: tb} = shell_state, workspace, label) do
    # Snapshot current tab before leaving
    context = Map.from_struct(workspace)
    tb = TabBar.update_context(tb, tb.active_id, context)

    # Create file tab (TabBar.add auto-activates it)
    {tb, new_tab} = TabBar.add(tb, :file, label)
    workspace = WorkspaceState.sync_active_window_buffer(workspace)

    # Snapshot the new tab's context
    new_context = Map.from_struct(workspace)
    tb = TabBar.update_context(tb, new_tab.id, new_context)

    Log.debug(:editor, fn ->
      "[tab] on_buffer_added new file tab=#{new_tab.id} label=#{label}"
    end)

    {%{shell_state | tab_bar: tb}, workspace}
  end

  @spec restore_workspace(WorkspaceState.t(), map()) :: WorkspaceState.t()
  defp restore_workspace(workspace, context) when is_map(context) and map_size(context) > 0 do
    Enum.reduce(WorkspaceState.field_names(), workspace, fn field, acc ->
      case Map.fetch(context, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp restore_workspace(workspace, _context), do: workspace

  # Resets the active window's content type from agent_chat back to buffer.
  @spec reset_active_window_to_buffer(WorkspaceState.t()) :: WorkspaceState.t()
  defp reset_active_window_to_buffer(workspace) do
    %{windows: %{map: map, active: id}, buffers: buffers} = workspace
    window = Map.get(map, id)

    case window do
      %Window{content: {:buffer, _}} ->
        workspace

      %Window{} ->
        updated = %{
          Window.invalidate(window)
          | buffer: buffers.active,
            content: Content.buffer(buffers.active)
        }

        %{workspace | windows: %{workspace.windows | map: Map.put(map, id, updated)}}

      nil ->
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
end
