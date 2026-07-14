defmodule MingaEditor.WindowFocus do
  @moduledoc "Focused workflow for window focus, buffer cursor calls, and shell focus presentation."

  alias Minga.Buffer
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
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
      state
      |> then(fn state ->
        %{
          state
          | workspace: SessionState.focus_window(state.workspace, target_id, outgoing_cursor)
        }
      end)
      |> blur_bottom_panel()
    else
      :error -> state
    end
  catch
    :exit, _reason -> state
  end

  @doc "Restores focus without reading the outgoing window's buffer, for popup dismissal."
  @spec restore_focus(state(), Window.id()) :: {:ok, state()} | :error
  def restore_focus(%EditorState{} = state, target_id) do
    with {:ok, target_window} <- Windows.fetch(state.workspace.windows, target_id),
         :ok <- restore_target_cursor(target_window) do
      restored =
        state
        |> then(fn state ->
          %{state | workspace: SessionState.focus_window(state.workspace, target_id, nil)}
        end)
        |> blur_bottom_panel()

      {:ok, restored}
    end
  catch
    :exit, _reason -> :error
  end

  @doc "Repairs a window with a viable buffer or empty surface, then restores focus to it."
  @spec repair_focus(state(), Window.id()) :: {:ok, state()} | :error
  def repair_focus(%EditorState{} = state, target_id) do
    case Windows.fetch(state.workspace.windows, target_id) do
      {:ok, target_window} -> repair_focus_target(state, target_id, target_window)
      :error -> :error
    end
  end

  @doc "Focuses a surviving window after the active split was removed."
  @spec focus_surviving_window(state(), Windows.t(), Window.id()) :: state()
  def focus_surviving_window(%EditorState{} = state, %Windows{} = windows, target_id) do
    with {:ok, target_window} <- Windows.fetch(windows, target_id),
         :ok <- restore_target_cursor(target_window) do
      state
      |> then(fn state ->
        %{
          state
          | workspace: SessionState.focus_surviving_window(state.workspace, windows, target_id)
        }
      end)
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
    %{state | workspace: SessionState.remember_active_window_cursor(state.workspace, cursor)}
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

  @spec repair_focus_target(state(), Window.id(), Window.t()) :: {:ok, state()}
  defp repair_focus_target(%EditorState{} = state, target_id, %Window{cursor: cursor}) do
    case find_restorable_buffer(state.workspace.buffers.list, cursor) do
      {:ok, buffer} -> repair_focus_with_buffer(state, target_id, buffer)
      :error -> repair_focus_with_empty_surface(state, target_id)
    end
  end

  @spec find_restorable_buffer([pid()], SessionState.position()) :: {:ok, pid()} | :error
  defp find_restorable_buffer(buffers, cursor) do
    Enum.reduce_while(buffers, :error, fn buffer, :error ->
      case restore_buffer_cursor(buffer, cursor) do
        :ok -> {:halt, {:ok, buffer}}
        :error -> {:cont, :error}
      end
    end)
  end

  @spec restore_buffer_cursor(pid(), SessionState.position()) :: :ok | :error
  defp restore_buffer_cursor(buffer, cursor) when is_pid(buffer) do
    Buffer.move_to(buffer, cursor)
  catch
    :exit, _reason -> :error
  end

  @spec repair_focus_with_buffer(state(), Window.id(), pid()) :: {:ok, state()}
  defp repair_focus_with_buffer(%EditorState{} = state, target_id, buffer) do
    buffers = Buffers.switch_to_pid(state.workspace.buffers, buffer)

    repaired =
      state
      |> then(fn state ->
        %{state | workspace: SessionState.focus_window(state.workspace, target_id, nil)}
      end)
      |> then(fn state ->
        %{state | workspace: SessionState.activate_buffer(state.workspace, buffers)}
      end)
      |> blur_bottom_panel()

    {:ok, repaired}
  end

  @spec repair_focus_with_empty_surface(state(), Window.id()) :: {:ok, state()}
  defp repair_focus_with_empty_surface(%EditorState{} = state, target_id) do
    repaired =
      state
      |> then(fn state ->
        %{state | workspace: SessionState.focus_window(state.workspace, target_id, nil)}
      end)
      |> then(fn state ->
        %{state | workspace: SessionState.enter_empty_state(state.workspace)}
      end)
      |> blur_bottom_panel()

    {:ok, repaired}
  end

  @spec blur_bottom_panel(state()) :: state()
  defp blur_bottom_panel(%EditorState{} = state) do
    shell_state = Runtime.state(state.shell_runtime)
    panel = shell_state |> TraditionalState.bottom_panel() |> BottomPanel.blur()
    shell_state = TraditionalState.set_bottom_panel(shell_state, panel)

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end
end
