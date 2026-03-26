defmodule Minga.Editor.Commands.WindowTest do
  use Minga.Test.EditingModelCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor
  alias Minga.Editor.State, as: EditorState

  defp start_editor(content \\ "hello\nworld\nfoo") do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 80,
        height: 24
      )

    {editor, buffer}
  end

  defp get_state(editor), do: :sys.get_state(editor)

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  defp send_keys(editor, keys) when is_list(keys) do
    Enum.each(keys, fn
      {cp, mods} -> send_key(editor, cp, mods)
      cp when is_integer(cp) -> send_key(editor, cp)
    end)
  end

  # SPC w v = vertical split
  defp split_vertical(editor) do
    send_keys(editor, [?\s, ?w, ?v])
  end

  # SPC w s = horizontal split
  defp split_horizontal(editor) do
    send_keys(editor, [?\s, ?w, ?s])
  end

  # SPC w d = close window
  defp close_window(editor) do
    send_keys(editor, [?\s, ?w, ?d])
  end

  describe "vertical split" do
    test "creates two windows showing the same buffer" do
      {editor, buffer} = start_editor()
      split_vertical(editor)
      state = get_state(editor)

      assert EditorState.split?(state)
      assert map_size(state.workspace.windows.map) == 2

      # Both windows reference the same buffer
      window_buffers =
        state.workspace.windows.map
        |> Map.values()
        |> Enum.map(& &1.buffer)
        |> Enum.uniq()

      assert window_buffers == [buffer]
    end

    test "each window has independent viewport dimensions" do
      {editor, _buffer} = start_editor()
      split_vertical(editor)
      state = get_state(editor)

      viewports =
        state.workspace.windows.map
        |> Map.values()
        |> Enum.map(& &1.viewport)

      # Vertical split: each window gets roughly half the width,
      # and rows equal the content area (total rows minus tab, status_bar, minibuffer).
      # 24 rows - tab(1) - status_bar(1) - minibuffer(1) = 21 content rows.
      Enum.each(viewports, fn vp ->
        assert vp.cols < 80
        assert vp.rows == 21
      end)
    end
  end

  describe "horizontal split" do
    test "creates two windows stacked vertically" do
      {editor, _buffer} = start_editor()
      split_horizontal(editor)
      state = get_state(editor)

      assert EditorState.split?(state)
      assert map_size(state.workspace.windows.map) == 2

      viewports =
        state.workspace.windows.map
        |> Map.values()
        |> Enum.map(& &1.viewport)

      # Horizontal split: each window gets roughly half the height
      Enum.each(viewports, fn vp ->
        assert vp.cols == 80
        assert vp.rows < 24
      end)
    end
  end

  describe "window navigation" do
    test "SPC w l moves focus to the right window after vertical split" do
      {editor, _buffer} = start_editor()
      split_vertical(editor)

      state_before = get_state(editor)
      initial_window = state_before.workspace.windows.active

      # Navigate right
      send_keys(editor, [?\s, ?w, ?l])
      state_after = get_state(editor)

      assert state_after.workspace.windows.active != initial_window
    end

    test "SPC w h moves focus back to the left window" do
      {editor, _buffer} = start_editor()
      split_vertical(editor)

      state_before = get_state(editor)
      initial_window = state_before.workspace.windows.active

      # Navigate right then left
      send_keys(editor, [?\s, ?w, ?l])
      send_keys(editor, [?\s, ?w, ?h])
      state_after = get_state(editor)

      assert state_after.workspace.windows.active == initial_window
    end

    test "SPC w j moves focus to the bottom window after horizontal split" do
      {editor, _buffer} = start_editor()
      split_horizontal(editor)

      state_before = get_state(editor)
      initial_window = state_before.workspace.windows.active

      send_keys(editor, [?\s, ?w, ?j])
      state_after = get_state(editor)

      assert state_after.workspace.windows.active != initial_window
    end

    test "navigating with no neighbor does nothing" do
      {editor, _buffer} = start_editor()
      split_vertical(editor)

      state_before = get_state(editor)

      # Try to go left from leftmost window — should stay
      send_keys(editor, [?\s, ?w, ?h])
      state_after = get_state(editor)

      assert state_after.workspace.windows.active == state_before.workspace.windows.active
    end
  end

  describe "close window" do
    test "closing a split returns to single window" do
      {editor, _buffer} = start_editor()
      split_vertical(editor)

      state = get_state(editor)
      assert EditorState.split?(state)

      close_window(editor)
      state = get_state(editor)

      refute EditorState.split?(state)
      assert map_size(state.workspace.windows.map) == 1
    end

    test "cannot close the last window" do
      {editor, _buffer} = start_editor()

      close_window(editor)
      state = get_state(editor)

      # Should show error message but not crash
      assert state.shell_state.status_msg == "Cannot close the last window"
    end

    test "focus moves to remaining window after close" do
      {editor, buffer} = start_editor()
      split_vertical(editor)

      # Navigate to right window
      send_keys(editor, [?\s, ?w, ?l])

      # Close it
      close_window(editor)
      state = get_state(editor)

      # Should be focused on the remaining window with the same buffer
      assert state.workspace.buffers.active == buffer
      refute EditorState.split?(state)
    end
  end

  describe "editing in split windows" do
    test "edits in active window are visible via buffer" do
      {editor, buffer} = start_editor("hello")
      split_vertical(editor)

      # Type in the active window (insert mode)
      send_key(editor, ?i)
      send_key(editor, ?X)
      send_key(editor, 27)

      # Buffer content should reflect the edit
      content = BufferServer.content(buffer)
      assert content =~ "X"
    end
  end
end
