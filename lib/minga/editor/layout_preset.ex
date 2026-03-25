defmodule Minga.Editor.LayoutPreset do
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

  `apply/3` takes the current editor state, a preset name, and the agent
  buffer pid. It modifies the window tree to match the preset topology,
  preserving the file buffer in the primary pane and placing the agent
  chat in the secondary pane.

  `restore_default/1` collapses the tree back to a single window with
  the file buffer, removing the agent chat pane.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Editor.WindowTree

  @type preset :: :default | :agent_right | :agent_bottom

  @doc """
  Applies a layout preset to the editor state.

  Creates a split window tree with the file buffer in the primary pane
  and the agent chat in the secondary pane. If an agent chat window
  already exists, this is a no-op (returns state unchanged).
  """
  @spec apply(EditorState.t(), preset(), pid()) :: EditorState.t()
  def apply(state, :agent_right, agent_buffer) do
    apply_split(state, agent_buffer, :vertical)
  end

  def apply(state, :agent_bottom, agent_buffer) do
    apply_split(state, agent_buffer, :horizontal)
  end

  def apply(state, :default, _agent_buffer) do
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
    state = maybe_switch_focus_away(state, agent_win_id)

    case WindowTree.close(state.workspace.windows.tree, agent_win_id) do
      {:ok, new_tree} ->
        map = Map.delete(state.workspace.windows.map, agent_win_id)
        windows = %{state.workspace.windows | tree: new_tree, map: map}
        state = %{state | workspace: %{state.workspace | windows: windows}}

        # If we were in agent scope, return to editor scope since the
        # agent pane is gone.
        if state.workspace.keymap_scope == :agent do
          %{state | workspace: %{state.workspace | keymap_scope: :editor}}
        else
          state
        end

      :error ->
        state
    end
  end

  @spec maybe_switch_focus_away(EditorState.t(), Window.id()) :: EditorState.t()
  defp maybe_switch_focus_away(state, closing_id) do
    if state.workspace.windows.active == closing_id do
      case find_non_agent_window(state) do
        {buf_win_id, window} ->
          scope = EditorState.scope_for_content(window.content, state.workspace.keymap_scope)

          EditorState.update_workspace(state, fn ws ->
            %{ws | windows: %{ws.windows | active: buf_win_id}, keymap_scope: scope}
          end)

        nil ->
          state
      end
    else
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

  @spec apply_split(EditorState.t(), pid(), :vertical | :horizontal) :: EditorState.t()
  defp apply_split(state, agent_buffer, direction) do
    # If an agent chat window already exists, just return
    if has_agent_chat?(state) do
      state
    else
      # Create a new agent chat window
      next_id = state.workspace.windows.next_id
      rows = state.workspace.viewport.rows
      cols = state.workspace.viewport.cols
      agent_window = Window.new_agent_chat(next_id, agent_buffer, rows, cols)

      # Split the active window to add the agent pane
      active_id = state.workspace.windows.active

      case WindowTree.split(state.workspace.windows.tree, active_id, direction, next_id) do
        {:ok, new_tree} ->
          new_map = Map.put(state.workspace.windows.map, next_id, agent_window)
          windows = %{state.workspace.windows | tree: new_tree, map: new_map, next_id: next_id + 1}
          %{state | workspace: %{state.workspace | windows: windows}}

        :error ->
          state
      end
    end
  end

  @spec find_agent_chat_window(EditorState.t()) :: {Window.id(), Window.t()} | nil
  defp find_agent_chat_window(state) do
    Enum.find(state.workspace.windows.map, fn {_id, window} ->
      Content.agent_chat?(window.content)
    end)
  end

  @spec find_non_agent_window(EditorState.t()) :: {Window.id(), Window.t()} | nil
  defp find_non_agent_window(state) do
    Enum.find(state.workspace.windows.map, fn {_id, window} ->
      Content.buffer?(window.content)
    end)
  end
end
