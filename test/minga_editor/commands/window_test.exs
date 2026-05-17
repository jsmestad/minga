defmodule MingaEditor.Commands.WindowTest do
  # Direct editor key-dispatch tests share global keymap/options servers, so CI concurrency can change leader routing.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor
  alias MingaEditor.Commands.Movement
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows

  @sync_timeout 30_000

  defp start_editor(content \\ "hello\nworld\nfoo") do
    {:ok, buffer} = BufferProcess.start_link(content: content)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 80,
        height: 24,
        editing_model: :vim
      )

    {editor, buffer}
  end

  defp start_command_state(content \\ "hello\nworld\nfoo") do
    {:ok, buffer} = BufferProcess.start_link(content: content)
    {:ok, options} = Options.start_link(name: nil)

    state =
      Startup.build_initial_state(
        port_manager: nil,
        options_server: options,
        buffer: buffer,
        width: 80,
        height: 24,
        editing_model: :vim
      )

    {state, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    :sys.get_state(editor, @sync_timeout)
  end

  defp send_keys(editor, keys) when is_list(keys) do
    Enum.reduce(keys, nil, fn
      {cp, mods}, _state -> send_key(editor, cp, mods)
      cp, _state when is_integer(cp) -> send_key(editor, cp)
    end)
  end

  defp split_vertical(editor), do: send_keys(editor, [?\s, ?w, ?v])
  defp split_horizontal(editor), do: send_keys(editor, [?\s, ?w, ?s])
  defp close_window(editor), do: send_keys(editor, [?\s, ?w, ?d])
  defp window_count(state), do: map_size(state.workspace.windows.map)

  describe "split command state" do
    @describetag layer: :command_state

    test "vertical split creates two windows showing the same buffer" do
      {state, buffer} = start_command_state()

      result = Movement.execute(state, :split_vertical)

      assert Windows.split?(result.workspace.windows)
      assert window_count(result) == 2

      window_buffers =
        result.workspace.windows.map |> Map.values() |> Enum.map(& &1.buffer) |> Enum.uniq()

      assert window_buffers == [buffer]
    end

    test "vertical split gives each window independent viewport dimensions" do
      {state, _buffer} = start_command_state()

      result = Movement.execute(state, :split_vertical)
      viewports = result.workspace.windows.map |> Map.values() |> Enum.map(& &1.viewport)

      Enum.each(viewports, fn viewport ->
        assert viewport.cols < 80
        assert viewport.rows == 21
      end)
    end

    test "horizontal split creates two windows stacked vertically" do
      {state, _buffer} = start_command_state()

      result = Movement.execute(state, :split_horizontal)
      viewports = result.workspace.windows.map |> Map.values() |> Enum.map(& &1.viewport)

      assert Windows.split?(result.workspace.windows)
      assert window_count(result) == 2

      Enum.each(viewports, fn viewport ->
        assert viewport.cols == 80
        assert viewport.rows < 24
      end)
    end
  end

  describe "window navigation command state" do
    @describetag layer: :command_state

    test "window_right moves focus to the right window after vertical split" do
      {state, _buffer} = start_command_state()
      state = Movement.execute(state, :split_vertical)
      initial_window = state.workspace.windows.active

      result = Movement.execute(state, :window_right)

      assert result.workspace.windows.active != initial_window
    end

    test "window_left moves focus back to the left window" do
      {state, _buffer} = start_command_state()
      state = Movement.execute(state, :split_vertical)
      initial_window = state.workspace.windows.active

      result = state |> Movement.execute(:window_right) |> Movement.execute(:window_left)

      assert result.workspace.windows.active == initial_window
    end

    test "window_down moves focus to the bottom window after horizontal split" do
      {state, _buffer} = start_command_state()
      state = Movement.execute(state, :split_horizontal)
      initial_window = state.workspace.windows.active

      result = Movement.execute(state, :window_down)

      assert result.workspace.windows.active != initial_window
    end

    test "navigating with no neighbor preserves the active window" do
      {state, _buffer} = start_command_state()
      state = Movement.execute(state, :split_vertical)

      result = Movement.execute(state, :window_left)

      assert result.workspace.windows.active == state.workspace.windows.active
    end
  end

  describe "close window command state" do
    @describetag layer: :command_state

    test "closing a split returns to a single window" do
      {state, _buffer} = start_command_state()
      state = Movement.execute(state, :split_vertical)
      assert Windows.split?(state.workspace.windows)

      result = Movement.execute(state, :window_close)

      refute Windows.split?(result.workspace.windows)
      assert window_count(result) == 1
    end

    test "cannot close the last window" do
      {state, _buffer} = start_command_state()

      result = Movement.execute(state, :window_close)

      assert result.shell_state.status_msg == "Cannot close the last window"
      refute Windows.split?(result.workspace.windows)
    end

    test "focus moves to the remaining window after close" do
      {state, buffer} = start_command_state()

      result =
        state
        |> Movement.execute(:split_vertical)
        |> Movement.execute(:window_right)
        |> Movement.execute(:window_close)

      assert result.workspace.buffers.active == buffer
      refute Windows.split?(result.workspace.windows)
    end

    test "closing a split restores the surviving window cursor into the buffer" do
      {state, buffer} = start_command_state("hello\nworld")

      state =
        state
        |> Movement.execute(:split_vertical)
        |> Movement.execute(:window_right)

      BufferProcess.move_to(buffer, {0, 2})
      state = EditorState.sync_active_window_cursor(state)
      assert state.workspace.windows.active == 2
      assert state.workspace.windows.map[2].cursor == {0, 2}

      result = Movement.execute(state, :window_close)

      assert BufferProcess.cursor(buffer) == {0, 0}
      assert result.workspace.windows.active == 1
      assert result.workspace.windows.map[1].cursor == {0, 0}
      refute Windows.split?(result.workspace.windows)
    end
  end

  describe "window key-routing editor integration smoke" do
    @describetag layer: :editor_integration

    test "SPC w v routes to vertical split" do
      {editor, _buffer} = start_editor()

      state = split_vertical(editor)

      assert Windows.split?(state.workspace.windows)
      assert window_count(state) == 2
    end

    test "SPC w l routes focus to the right window after a vertical split" do
      {editor, _buffer} = start_editor()
      state = split_vertical(editor)
      initial_window = state.workspace.windows.active

      state = send_keys(editor, [?\s, ?w, ?l])

      assert state.workspace.windows.active != initial_window
    end

    test "SPC w d routes to window close" do
      {editor, _buffer} = start_editor()
      split_horizontal(editor)

      state = close_window(editor)

      refute Windows.split?(state.workspace.windows)
      assert window_count(state) == 1
    end

    test "edits in an active split window are written to the shared buffer" do
      {editor, buffer} = start_editor("hello")
      split_vertical(editor)

      send_key(editor, ?i)
      send_key(editor, ?X)
      send_key(editor, 27)

      assert BufferProcess.content(buffer) =~ "X"
    end
  end
end
