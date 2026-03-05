defmodule Minga.Editor.Commands.Terminal do
  @moduledoc """
  Terminal toggle command for the embedded terminal split.

  `SPC o t` cycles through three states:
  1. No terminal open → open a bottom split (30% height) and focus it
  2. Terminal open but not focused → focus it
  3. Terminal open and focused → close it
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.{Window, WindowTree}
  alias Minga.Port.{Manager, Protocol}
  alias Minga.Terminal

  @type state :: EditorState.t()

  @doc "Toggles the embedded terminal split."
  @spec execute(state(), :toggle_terminal) :: state()
  def execute(%{terminal: nil} = state, :toggle_terminal) do
    open_terminal(state)
  end

  def execute(%{terminal: %Terminal{open: false}} = state, :toggle_terminal) do
    open_terminal(state)
  end

  def execute(%{terminal: %Terminal{open: true, focused: true}} = state, :toggle_terminal) do
    close_terminal(state)
  end

  def execute(%{terminal: %Terminal{open: true, focused: false}} = state, :toggle_terminal) do
    focus_terminal(state)
  end

  @doc "Handles the terminal_exited event from the Zig renderer."
  @spec handle_exited(state()) :: state()
  def handle_exited(%{terminal: nil} = state), do: state

  def handle_exited(%{terminal: %Terminal{open: true}} = state) do
    close_terminal(state)
  end

  def handle_exited(state), do: state

  # ── Private ──────────────────────────────────────────────────────────────

  @spec open_terminal(state()) :: state()
  defp open_terminal(%EditorState{windows: %{tree: nil}} = state), do: state

  defp open_terminal(%EditorState{} = state) do
    terminal = state.terminal || Terminal.new()
    ws = state.windows

    # Create a new window for the terminal in a bottom horizontal split
    new_id = ws.next_id
    root_tree = ws.tree

    # Split the root horizontally: editor on top, terminal on bottom
    new_tree = {:split, :horizontal, root_tree, {:leaf, new_id}, 0}

    # Calculate terminal dimensions from the layout
    screen = EditorState.screen_rect(state)
    layouts = WindowTree.layout(new_tree, screen)

    {row_offset, col_offset, cols, rows} =
      case List.keyfind(layouts, new_id, 0) do
        nil -> {0, 0, 80, 12}
        {^new_id, rect} -> rect
      end

    # Create a placeholder window for the terminal leaf in the tree
    # (it won't have a real buffer, but the tree needs the ID)
    active_buf = state.buffers.active
    placeholder_window = Window.new(new_id, active_buf, rows, cols, {0, 0})

    terminal = Terminal.open(terminal, rows, cols, row_offset, col_offset, new_id)

    # Send the open_terminal command to Zig
    cmd = Protocol.encode_open_terminal(terminal.shell, rows, cols, row_offset, col_offset)
    Manager.send_commands(state.port_manager, [cmd])

    # Resize existing windows to account for the new split
    state = %{
      state
      | windows: %{
          ws
          | tree: new_tree,
            map: Map.put(ws.map, new_id, placeholder_window),
            next_id: new_id + 1
        },
        terminal: terminal,
        mode: :terminal,
        status_msg: "TERMINAL (ESC to return)"
    }

    resize_windows(state)
  end

  @spec close_terminal(state()) :: state()
  defp close_terminal(%EditorState{terminal: %Terminal{window_id: nil}} = state) do
    %{state | terminal: Terminal.close(state.terminal)}
  end

  defp close_terminal(%EditorState{terminal: %Terminal{window_id: wid}} = state) do
    # Send close command to Zig
    Manager.send_commands(state.port_manager, [Protocol.encode_close_terminal()])

    ws = state.windows

    # Remove the terminal window from the tree
    new_tree =
      case WindowTree.close(ws.tree, wid) do
        {:ok, tree} -> tree
        :error -> ws.tree
      end

    # If we were focused on the terminal, switch to a real window
    new_active =
      if ws.active == wid do
        hd(WindowTree.leaves(new_tree))
      else
        ws.active
      end

    new_map = Map.delete(ws.map, wid)
    active_window = Map.get(new_map, new_active)
    active_buf = if active_window, do: active_window.buffer, else: state.buffers.active

    %{
      state
      | windows: %{ws | tree: new_tree, map: new_map, active: new_active},
        terminal: Terminal.close(state.terminal),
        mode: :normal,
        mode_state: nil,
        buffers: %{state.buffers | active: active_buf},
        status_msg: nil
    }
  end

  @spec focus_terminal(state()) :: state()
  defp focus_terminal(state) do
    terminal = Terminal.set_focus(state.terminal, true)
    Manager.send_commands(state.port_manager, [Protocol.encode_terminal_focus(true)])

    %{
      state
      | terminal: terminal,
        mode: :terminal,
        status_msg: "TERMINAL (ESC to return)"
    }
  end

  @spec resize_windows(state()) :: state()
  defp resize_windows(%EditorState{} = state) do
    screen = EditorState.screen_rect(state)
    layouts = WindowTree.layout(state.windows.tree, screen)

    state =
      Enum.reduce(layouts, state, fn {id, {_row, _col, width, height}}, acc ->
        EditorState.update_window(acc, id, &Window.resize(&1, height, width))
      end)

    # If terminal is open, update its dimensions and tell Zig
    case state.terminal do
      %Terminal{open: true, window_id: wid} when is_integer(wid) ->
        case List.keyfind(layouts, wid, 0) do
          {^wid, {row_offset, col_offset, cols, rows}} ->
            terminal = Terminal.resize(state.terminal, rows, cols, row_offset, col_offset)
            cmd = Protocol.encode_resize_terminal(rows, cols, row_offset, col_offset)
            Manager.send_commands(state.port_manager, [cmd])
            %{state | terminal: terminal}

          nil ->
            state
        end

      _ ->
        state
    end
  end
end
