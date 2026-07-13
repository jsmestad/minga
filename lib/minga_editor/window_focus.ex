defmodule MingaEditor.WindowFocus do
  @moduledoc "Focused workflow for window focus, buffer cursor calls, and shell focus presentation."

  alias Minga.Buffer
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.BottomPanel
  alias MingaEditor.Window

  @type state :: EditorState.t()

  @doc "Focuses a window after saving and restoring its buffer cursor state."
  @spec focus(state(), Window.id()) :: state()
  def focus(%EditorState{workspace: %{windows: %{active: active}}} = state, target_id)
      when target_id == active,
      do: blur_bottom_panel(state)

  def focus(%EditorState{} = state, target_id) do
    windows = state.workspace.windows

    with {:ok, old_window} <- Windows.fetch(windows, windows.active),
         {:ok, target_window} <- Windows.fetch(windows, target_id),
         {:ok, outgoing_cursor} <- outgoing_cursor(old_window, state.workspace.buffers.active),
         :ok <- restore_target_cursor(target_window) do
      workspace = SessionState.focus_window(state.workspace, target_id, outgoing_cursor)

      state
      |> EditorState.set_workspace(workspace)
      |> blur_bottom_panel()
    else
      :error -> state
    end
  catch
    :exit, _reason -> state
  end

  @doc "Restores focus without reading the outgoing window's buffer, for popup dismissal."
  @spec restore_focus(state(), Window.id()) :: state()
  def restore_focus(%EditorState{} = state, target_id) do
    with {:ok, target_window} <- Windows.fetch(state.workspace.windows, target_id),
         :ok <- restore_target_cursor(target_window) do
      workspace = SessionState.focus_window(state.workspace, target_id, nil)

      state
      |> EditorState.set_workspace(workspace)
      |> blur_bottom_panel()
    else
      :error -> state
    end
  catch
    :exit, _reason -> state
  end

  @doc "Focuses a surviving window after the active split was removed."
  @spec focus_surviving_window(state(), Windows.t(), Window.id()) :: state()
  def focus_surviving_window(%EditorState{} = state, %Windows{} = windows, target_id) do
    with {:ok, target_window} <- Windows.fetch(windows, target_id),
         :ok <- restore_target_cursor(target_window) do
      workspace = SessionState.focus_surviving_window(state.workspace, windows, target_id)

      state
      |> EditorState.set_workspace(workspace)
      |> blur_bottom_panel()
    else
      :error -> state
    end
  catch
    :exit, _reason -> state
  end

  @doc "Snapshots the active buffer cursor into its matching window."
  @spec remember_active_cursor(state()) :: state()
  def remember_active_cursor(%EditorState{workspace: %{buffers: %{active: buffer}}} = state)
      when is_pid(buffer) do
    cursor = Buffer.cursor(buffer)
    workspace = SessionState.remember_active_window_cursor(state.workspace, cursor)
    EditorState.set_workspace(state, workspace)
  catch
    :exit, _reason -> state
  end

  def remember_active_cursor(%EditorState{} = state), do: state

  @spec outgoing_cursor(Window.t(), pid() | nil) :: {:ok, SessionState.position() | nil}
  defp outgoing_cursor(%Window{content: {:buffer, _}}, active_buffer) when is_pid(active_buffer),
    do: {:ok, Buffer.cursor(active_buffer)}

  defp outgoing_cursor(%Window{}, _active_buffer), do: {:ok, nil}

  @spec restore_target_cursor(Window.t()) :: :ok
  defp restore_target_cursor(%Window{content: {:buffer, buffer}, cursor: cursor})
       when is_pid(buffer) do
    Buffer.move_to(buffer, cursor)
  end

  defp restore_target_cursor(%Window{}), do: :ok

  @spec blur_bottom_panel(state()) :: state()
  defp blur_bottom_panel(%EditorState{} = state) do
    runtime =
      Runtime.update_traditional_state(state.shell_runtime, fn shell_state ->
        panel = shell_state |> TraditionalState.bottom_panel() |> BottomPanel.blur()
        TraditionalState.set_bottom_panel(shell_state, panel)
      end)

    EditorState.apply_shell_runtime_transition(state, runtime)
  end
end
