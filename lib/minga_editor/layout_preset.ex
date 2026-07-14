defmodule MingaEditor.LayoutPreset do
  @moduledoc """
  Window tree layout presets.

  A preset defines a window tree topology with content type assignments.
  Applying a preset rearranges the window tree to match the topology,
  creating or removing windows as needed. The user's file buffer stays
  in one pane; the agent chat goes in another.

  ## Presets

  | Name | Layout | Use case |
  |------|--------|----------|
  | `:default` | Single window (file buffer) | Normal file editing |
  | `:agent_right` | File left (60%), agent right (40%) | Side-by-side coding + agent |
  | `:agent_bottom` | File top (65%), agent bottom (35%) | Horizontal split with agent |

  ## How it works

  `apply/3` takes the current editor state, a preset name, and the current agent session pid. It modifies the window tree to match the preset topology, preserving the file buffer in the primary pane and placing the semantic agent chat in the secondary pane.

  `restore_default/1` collapses the tree back to a single window with
  the file buffer, removing the agent chat pane.
  """

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @type preset :: :default | :agent_right | :agent_bottom

  @doc """
  Applies a layout preset to the editor state.

  Creates a split window tree with the file buffer in the primary pane
  and the agent chat in the secondary pane. If an agent chat window
  already exists, this is a no-op (returns state unchanged).
  """
  @spec apply(EditorState.t(), preset(), pid() | nil) :: EditorState.t()
  def apply(state, :agent_right, _session_pid) do
    apply_split(state, :vertical)
  end

  def apply(state, :agent_bottom, _session_pid) do
    apply_split(state, :horizontal)
  end

  def apply(state, :default, _session_pid) do
    restore_default(state)
  end

  @doc """
  Restores the default single-window layout, removing agent chat panes.
  """
  @spec restore_default(EditorState.t()) :: EditorState.t()
  def restore_default(state) do
    case find_agent_chat_window(state) do
      nil -> state
      {agent_win_id, _window} -> remove_agent_window(state, agent_win_id)
    end
  end

  @spec remove_agent_window(EditorState.t(), Window.id()) :: EditorState.t()
  defp remove_agent_window(state, agent_win_id) do
    state
    |> maybe_switch_focus_away(agent_win_id)
    |> remove_inactive_agent_window(agent_win_id)
  end

  @spec remove_inactive_agent_window(EditorState.t(), Window.id()) :: EditorState.t()
  defp remove_inactive_agent_window(
         %{workspace: %{windows: %{active: active}}} = state,
         agent_win_id
       )
       when active == agent_win_id,
       do: state

  defp remove_inactive_agent_window(state, agent_win_id) do
    case Windows.remove_window(state.workspace.windows, agent_win_id) do
      {:ok, windows} ->
        state = %{
          state
          | workspace: MingaEditor.Session.State.set_windows(state.workspace, windows)
        }

        # If we were in agent scope, return to editor scope since the
        # agent pane is gone.
        if state.workspace.keymap_scope == :agent do
          %{
            state
            | workspace: MingaEditor.Session.State.set_keymap_scope(state.workspace, :editor)
          }
        else
          state
        end

      :error ->
        state
    end
  end

  @spec maybe_switch_focus_away(EditorState.t(), Window.id()) :: EditorState.t()
  defp maybe_switch_focus_away(%{workspace: %{windows: %{active: active}}} = state, closing_id)
       when active != closing_id,
       do: state

  defp maybe_switch_focus_away(state, _closing_id) do
    case find_non_agent_window(state) do
      {buf_win_id, _window} ->
        MingaEditor.WindowFocus.focus(state, buf_win_id)

      nil ->
        state
    end
  end

  @doc """
  Returns true if the window tree currently contains an agent chat pane.
  """
  @spec has_agent_chat?(EditorState.t()) :: boolean()
  def has_agent_chat?(state) do
    find_agent_chat_window(state) != nil
  end

  # ── Private ───────────────────────────────────────────────────────────────

  @spec apply_split(EditorState.t(), :vertical | :horizontal) :: EditorState.t()
  defp apply_split(state, direction) do
    # If an agent chat window already exists, just return
    if has_agent_chat?(state) do
      state
    else
      {next_id, windows} = Windows.allocate_id(state.workspace.windows)
      rows = state.frontend.terminal_viewport.rows
      cols = state.frontend.terminal_viewport.cols
      agent_window = Window.new_agent_chat(next_id, rows, cols)

      # Split the active window to add the agent pane
      active_id = windows.active

      case WindowTree.split(windows.tree, active_id, direction, next_id) do
        {:ok, new_tree} ->
          windows =
            windows
            |> Windows.set_tree(new_tree)
            |> Windows.add_window(agent_window)

          %{state | workspace: MingaEditor.Session.State.set_windows(state.workspace, windows)}

        :error ->
          state
      end
    end
  end

  @spec find_agent_chat_window(EditorState.t()) :: {Window.id(), Window.t()} | nil
  defp find_agent_chat_window(state) do
    Windows.find_agent_chat(state.workspace.windows)
  end

  @spec find_non_agent_window(EditorState.t()) :: {Window.id(), Window.t()} | nil
  defp find_non_agent_window(state) do
    Windows.find_buffer_window(state.workspace.windows)
  end
end
