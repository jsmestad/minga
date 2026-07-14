defmodule MingaEditor.WindowFocus do
  @moduledoc "Focused workflow for window focus, buffer cursor calls, and shell focus presentation."

  alias Minga.Buffer
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Window

  @type state :: EditorState.t()
  @type focus_failure :: :window_not_found | :cursor_source_mismatch | :buffer_unavailable
  @type focus_result :: {:ok, state()} | {:error, focus_failure()}

  @doc "Focuses a window after saving and restoring its buffer cursor state."
  @spec focus(state(), Window.id()) :: state()
  def focus(%EditorState{} = state, target_id) do
    case focus_result(state, target_id) do
      {:ok, focused} -> focused
      {:error, _reason} -> state
    end
  end

  @doc "Focuses a window and reports why an ownership-safe transition was rejected."
  @spec focus_result(state(), Window.id()) :: focus_result()
  def focus_result(
        %EditorState{workspace: %{windows: %{active: active}}} = state,
        target_id
      )
      when target_id == active,
      do: {:ok, blur_bottom_panel(state)}

  def focus_result(%EditorState{} = state, target_id) do
    windows = state.workspace.windows

    with {:ok, old_window} <- fetch_window(windows, windows.active),
         {:ok, target_window} <- fetch_window(windows, target_id),
         {:ok, outgoing_cursor} <- outgoing_cursor(old_window, state.workspace.buffers.active),
         :ok <- restore_target_cursor(target_window) do
      focused =
        state
        |> then(fn state ->
          %{
            state
            | workspace: SessionState.focus_window(state.workspace, target_id, outgoing_cursor)
          }
        end)
        |> blur_bottom_panel()

      {:ok, focused}
    end
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
    else
      _failure -> :error
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
      _failure -> state
    end
  catch
    :exit, _reason -> state
  end

  @doc "Snapshots the active cursor only when the active window owns its buffer source."
  @spec remember_active_cursor(state()) :: state()
  def remember_active_cursor(%EditorState{} = state) do
    case remember_active_cursor_result(state) do
      {:ok, remembered} -> remembered
      {:error, _reason} -> state
    end
  end

  @doc "Snapshots the active cursor and reports ownership failures without changing state."
  @spec remember_active_cursor_result(state()) :: focus_result()
  def remember_active_cursor_result(%EditorState{} = state) do
    windows = state.workspace.windows

    with {:ok, outgoing_window} <- fetch_window(windows, windows.active),
         {:ok, cursor} <- outgoing_cursor(outgoing_window, state.workspace.buffers.active) do
      remember_cursor_result(state, cursor)
    end
  end

  @spec remember_cursor_result(state(), SessionState.position() | nil) :: {:ok, state()}
  defp remember_cursor_result(state, {_, _} = cursor) do
    {:ok,
     %{
       state
       | workspace: SessionState.remember_active_window_cursor(state.workspace, cursor)
     }}
  end

  defp remember_cursor_result(state, nil), do: {:ok, state}

  @spec fetch_window(Windows.t(), Window.id()) :: {:ok, Window.t()} | {:error, :window_not_found}
  defp fetch_window(windows, id) do
    case Windows.fetch(windows, id) do
      {:ok, window} -> {:ok, window}
      :error -> {:error, :window_not_found}
    end
  end

  @spec outgoing_cursor(Window.t(), pid() | nil) ::
          {:ok, SessionState.position() | nil} | {:error, focus_failure()}
  defp outgoing_cursor(%Window{content: {:buffer, buffer}}, buffer) when is_pid(buffer) do
    {:ok, Buffer.cursor(buffer)}
  catch
    :exit, _reason -> {:error, :buffer_unavailable}
  end

  defp outgoing_cursor(%Window{content: {:buffer, _buffer}}, _active_buffer),
    do: {:error, :cursor_source_mismatch}

  defp outgoing_cursor(%Window{}, nil), do: {:ok, nil}
  defp outgoing_cursor(%Window{}, _active_buffer), do: {:error, :cursor_source_mismatch}

  @spec restore_target_cursor(Window.t()) :: :ok | {:error, :buffer_unavailable}
  defp restore_target_cursor(%Window{content: {:buffer, buffer}, cursor: cursor})
       when is_pid(buffer) do
    Buffer.move_to(buffer, cursor)
  catch
    :exit, _reason -> {:error, :buffer_unavailable}
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
  defp blur_bottom_panel(%EditorState{} = state),
    do: %{state | shell_runtime: Runtime.blur_bottom_panel(state.shell_runtime)}
end
