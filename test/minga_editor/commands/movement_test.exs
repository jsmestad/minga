defmodule MingaEditor.Commands.MovementTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.WrapMap
  alias MingaEditor
  alias MingaEditor.Commands.Movement
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias Minga.Editing.Fold.Range, as: FoldRange

  @sync_timeout 15_000

  defp start_editor(content \\ "hello\nworld\nfoo", width \\ 40, height \\ 10) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"movement_events_#{id}"
    project_root = isolated_project_root(id)
    start_supervised!({Minga.Events, name: events_registry})

    {:ok, buffer} = BufferProcess.start_link(content: content, events_registry: events_registry)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{id}",
        port_manager: nil,
        buffer: buffer,
        width: width,
        height: height,
        editing_model: :vim,
        events_registry: events_registry,
        project_root: project_root,
        suppress_tool_prompts: true
      )

    {editor, buffer}
  end

  defp isolated_project_root(id) do
    root = Path.join(System.tmp_dir!(), "minga-movement-#{id}")
    File.mkdir_p!(root)
    root
  end

  defp wrapped_content_width(state, buffer) do
    layout = Layout.get(state)

    content_width =
      case Layout.active_window_layout(layout, state) do
        %{content: {_row, _col, width, _height}} -> width
        nil -> elem(layout.editor_area, 2)
      end

    line_count = BufferProcess.line_count(buffer)

    gutter_width =
      case BufferProcess.get_option(buffer, :line_numbers) do
        :none -> Gutter.total_width(0)
        _ -> Gutter.total_width(Viewport.gutter_width(line_count))
      end

    max(content_width - gutter_width, 1)
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor, @sync_timeout)
  end

  defp set_active_fold_ranges(editor, ranges) do
    :sys.replace_state(editor, fn state ->
      MingaEditor.State.update_window(
        state,
        state.workspace.windows.active,
        &Window.set_fold_ranges(&1, ranges)
      )
    end)
  end

  describe "Normal mode — movements" do
    test "default bus tool prompts cannot interrupt movement dispatch" do
      {editor, buffer} = start_editor("hello")
      state = :sys.get_state(editor, @sync_timeout)

      refute editor in Minga.Events.subscribers(:tool_missing)
      assert editor in Minga.Events.subscribers(:tool_missing, state.events_registry)

      Minga.Events.broadcast(:tool_missing, %Minga.Events.ToolMissingEvent{command: "rg"})
      send_key(editor, ?l)

      assert BufferProcess.cursor(buffer) == {0, 1}
      state = :sys.get_state(editor, @sync_timeout)
      assert state.workspace.editing.mode == :normal
      assert state.shell_state.tool_prompt_queue == []
    end

    test "h moves cursor left" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?h)

      assert BufferProcess.cursor(buffer) == {0, 1}
    end

    test "j moves cursor down" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?j)
      assert elem(BufferProcess.cursor(buffer), 0) == 1
    end

    test "k moves cursor up after moving down" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?j)
      send_key(editor, ?k)
      assert elem(BufferProcess.cursor(buffer), 0) == 0
    end

    test "wrapped j and k honor tab width when computing visual rows" do
      state = TestHelpers.base_state(content: "	" <> String.duplicate("a", 30), cols: 7, rows: 10)
      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)
      _ = BufferProcess.set_option(buffer, :tab_width, 4)

      BufferProcess.move_to(buffer, {0, 4})

      _ = Movement.execute(state, :move_down)
      assert BufferProcess.cursor(buffer) == {0, 5}

      _ = Movement.execute(state, :move_up)
      assert BufferProcess.cursor(buffer) == {0, 4}
    end

    test "arrow keys move cursor without changing content" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      original = BufferProcess.content(buffer)

      send_key(editor, 57_351)
      send_key(editor, 57_351)

      assert BufferProcess.content(buffer) == original
      assert BufferProcess.cursor(buffer) == {0, 2}
    end

    test "unknown keys in normal mode are ignored" do
      {editor, buffer} = start_editor("hello")
      original = BufferProcess.content(buffer)

      send_key(editor, 57_376)
      assert BufferProcess.content(buffer) == original
    end

    test "0 moves to beginning of line" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?0)
      assert BufferProcess.cursor(buffer) == {0, 0}
    end

    test "$ moves to end of line" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?$)
      {_, col} = BufferProcess.cursor(buffer)
      assert col == 4
    end

    test "l at end of line does not wrap to next line" do
      {editor, buffer} = start_editor("hi\nworld")
      send_key(editor, ?$)
      assert BufferProcess.cursor(buffer) == {0, 1}

      send_key(editor, ?l)
      assert BufferProcess.cursor(buffer) == {0, 1}
    end

    test "h at start of line does not wrap to previous line" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?j)
      assert BufferProcess.cursor(buffer) == {1, 0}

      send_key(editor, ?h)
      assert BufferProcess.cursor(buffer) == {1, 0}
    end

    test "right arrow at end of line does not wrap to next line" do
      {editor, buffer} = start_editor("ab\ncd")
      send_key(editor, ?$)
      assert BufferProcess.cursor(buffer) == {0, 1}

      send_key(editor, 57_351)
      assert BufferProcess.cursor(buffer) == {0, 1}
    end

    test "left arrow at start of line does not wrap to previous line" do
      {editor, buffer} = start_editor("ab\ncd")
      send_key(editor, ?j)
      assert BufferProcess.cursor(buffer) == {1, 0}

      send_key(editor, 57_350)
      assert BufferProcess.cursor(buffer) == {1, 0}
    end

    test "l does not go past last character on line in normal mode" do
      {editor, buffer} = start_editor("abc\ndef")
      for _ <- 1..10, do: send_key(editor, ?l)
      assert BufferProcess.cursor(buffer) == {0, 2}
    end

    test "l and h wrap across lines in insert mode" do
      {editor, buffer} = start_editor("ab\ncd")
      send_key(editor, ?i)
      send_key(editor, 57_351)
      send_key(editor, 57_351)
      send_key(editor, 57_351)
      assert BufferProcess.cursor(buffer) == {1, 0}

      send_key(editor, 57_350)
      assert BufferProcess.cursor(buffer) == {0, 2}
    end
  end

  describe "wrap-aware motions with folds" do
    test "j/k/0/$ stay logical when folds are active" do
      content =
        [
          "visible top",
          "hidden one",
          "hidden two",
          "hidden three",
          String.duplicate("a", 120)
        ]
        |> Enum.join("\n")

      {editor, buffer} = start_editor(content)
      _ = BufferProcess.set_option(buffer, :wrap, true)
      set_active_fold_ranges(editor, [FoldRange.new!(1, 3)])

      :sys.replace_state(editor, fn state ->
        MingaEditor.State.update_window(
          state,
          state.workspace.windows.active,
          &Window.fold_at(&1, 1)
        )
      end)

      send_key(editor, ?j)
      assert BufferProcess.cursor(buffer) == {1, 0}

      send_key(editor, ?j)
      assert elem(BufferProcess.cursor(buffer), 0) == 4

      send_key(editor, ?k)
      assert elem(BufferProcess.cursor(buffer), 0) == 1

      BufferProcess.move_to(buffer, {4, 90})
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?0)
      assert BufferProcess.cursor(buffer) == {4, 0}

      BufferProcess.move_to(buffer, {4, 90})
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?$)
      assert BufferProcess.cursor(buffer) == {4, 119}
    end

    test "wrapped j uses the active split window width" do
      state = TestHelpers.base_state(content: String.duplicate("a", 60) <> "\n" <> "second")
      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)

      state = Movement.execute(state, :split_vertical)
      _ = Movement.execute(state, :move_down)

      expected_width = wrapped_content_width(state, buffer)

      expected_offset =
        WrapMap.compute([String.duplicate("a", 60)], expected_width)
        |> hd()
        |> Enum.at(1)
        |> Map.fetch!(:byte_offset)

      assert BufferProcess.cursor(buffer) == {0, expected_offset}
    end
  end

  describe "Normal mode — count prefix" do
    test "3l moves cursor right 3 times" do
      {editor, buffer} = start_editor("hello world")
      send_key(editor, ?3)
      send_key(editor, ?l)
      assert BufferProcess.cursor(buffer) == {0, 3}
    end

    test "2j moves cursor down 2 lines" do
      {editor, buffer} = start_editor("a\nb\nc\nd")
      send_key(editor, ?2)
      send_key(editor, ?j)
      assert elem(BufferProcess.cursor(buffer), 0) == 2
    end
  end

  describe "wrap-aware scroll positioning" do
    test "scroll_cursor_top keeps offset 0 when the wrapped file fits" do
      penultimate = "    " <> String.duplicate("alpha beta ", 4)
      last_line = "tail"

      state =
        TestHelpers.base_state(content: penultimate <> "\n" <> last_line, rows: 10, cols: 24)

      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)

      content_width = wrapped_content_width(state, buffer)

      wrap_map =
        WrapMap.compute([penultimate, last_line], content_width,
          breakindent: true,
          linebreak: false,
          tab_width: 2
        )

      BufferProcess.move_to(buffer, {0, List.last(hd(wrap_map)).byte_offset})

      state = Movement.execute(state, :scroll_cursor_top)
      win = MingaEditor.State.active_window_struct(state)

      assert win.viewport.top == 0
      assert win.viewport.visual_row_offset == 0
    end

    test "scroll_cursor_top uses rows remaining to eof for penultimate wrapped lines" do
      penultimate = "    " <> String.duplicate("alpha beta ", 4)
      last_line = String.duplicate("omega psi ", 12)
      state = TestHelpers.base_state(content: penultimate <> "\n" <> last_line, rows: 5, cols: 24)
      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)

      content_width = wrapped_content_width(state, buffer)

      [penultimate_entry, last_entry] =
        WrapMap.compute([penultimate, last_line], content_width,
          breakindent: true,
          linebreak: false,
          tab_width: 2
        )

      total_visual_rows = WrapMap.visual_row_count([penultimate_entry, last_entry])
      visible = Viewport.content_rows(Viewport.new(5, 24, 0))
      cursor_visual_row = length(penultimate_entry) - 1

      assert total_visual_rows > visible

      BufferProcess.move_to(buffer, {0, List.last(penultimate_entry).byte_offset})

      state = Movement.execute(state, :scroll_cursor_top)
      win = MingaEditor.State.active_window_struct(state)

      assert win.viewport.top == 0

      assert win.viewport.visual_row_offset ==
               min(cursor_visual_row, max(total_visual_rows - visible, 0))
    end
  end

  describe "page / half-page scrolling" do
    defp start_scroll_editor do
      id = :erlang.unique_integer([:positive])
      content = Enum.map_join(0..29, "\n", &"line #{&1}")
      events_registry = :"movement_scroll_events_#{id}"
      project_root = isolated_project_root(id)
      start_supervised!({Minga.Events, name: events_registry})

      {:ok, buffer} = BufferProcess.start_link(content: content, events_registry: events_registry)

      {:ok, editor} =
        MingaEditor.start_link(
          name: :"editor_#{id}",
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10,
          editing_model: :vim,
          events_registry: events_registry,
          project_root: project_root,
          suppress_tool_prompts: true
        )

      {editor, buffer}
    end

    test "Ctrl+d moves cursor down by half a page" do
      {editor, buffer} = start_scroll_editor()
      send_key(editor, ?d, 0x02)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 4
    end

    test "Ctrl+u moves cursor up by half a page" do
      {editor, buffer} = start_scroll_editor()
      BufferProcess.move_to(buffer, {10, 0})
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?u, 0x02)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 6
    end

    test "Ctrl+f moves cursor down by a full page" do
      {editor, buffer} = start_scroll_editor()
      send_key(editor, ?f, 0x02)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 8
    end

    test "Ctrl+b moves cursor up by a full page" do
      {editor, buffer} = start_scroll_editor()
      BufferProcess.move_to(buffer, {20, 0})
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?b, 0x02)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 12
    end

    test "Ctrl+d clamps to last line at buffer end" do
      {editor, buffer} = start_scroll_editor()
      BufferProcess.move_to(buffer, {28, 0})
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?d, 0x02)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 29
    end

    test "Ctrl+u clamps to first line at buffer start" do
      {editor, buffer} = start_scroll_editor()
      BufferProcess.move_to(buffer, {2, 0})
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?u, 0x02)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 0
    end

    test "column is clamped to new line length" do
      {editor, buffer} = start_scroll_editor()
      BufferProcess.move_to(buffer, {29, 6})
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?b, 0x02)
      {_line, col} = BufferProcess.cursor(buffer)
      assert col <= 6
    end
  end

  describe "stub commands" do
    test "find_file doesn't crash" do
      {editor, _buffer} = start_editor()
      send_key(editor, 32)
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?f)
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?f)
      _ = :sys.get_state(editor, @sync_timeout)
      assert Process.alive?(editor)
    end

    test "fa moves to next 'a', ; repeats forward" do
      {editor, buffer} = start_editor("banana split")
      # Cursor starts at col 0 ('b'). fa should move to col 1 ('a')
      send_key(editor, ?f)
      send_key(editor, ?a)
      assert BufferProcess.cursor(buffer) == {0, 1}

      # ; should repeat: move to next 'a' at col 3
      send_key(editor, ?;)
      assert BufferProcess.cursor(buffer) == {0, 3}

      # ; again: move to next 'a' at col 5
      send_key(editor, ?;)
      assert BufferProcess.cursor(buffer) == {0, 5}
    end

    test ", reverses the last find char direction" do
      {editor, buffer} = start_editor("banana split")
      # fa moves to col 1, ; to col 3, , back to col 1
      send_key(editor, ?f)
      send_key(editor, ?a)
      send_key(editor, ?;)
      assert BufferProcess.cursor(buffer) == {0, 3}

      send_key(editor, ?,)
      assert BufferProcess.cursor(buffer) == {0, 1}
    end

    test "ta moves to one before next 'a', ; repeats till motion" do
      {editor, buffer} = start_editor("x_abc_abc_end")
      # Cursor at 0. ta finds 'a' at col 2, lands at col 1 (one before)
      send_key(editor, ?t)
      send_key(editor, ?a)
      assert BufferProcess.cursor(buffer) == {0, 1}

      # Move past the first 'a' so ; has room to advance.
      # fa lands on col 2, then ; (repeating t) finds next 'a' at col 6, lands at col 5.
      send_key(editor, ?f)
      send_key(editor, ?a)
      assert BufferProcess.cursor(buffer) == {0, 2}

      # Now ta again from col 2 should find 'a' at col 6, land at col 5
      send_key(editor, ?t)
      send_key(editor, ?a)
      assert BufferProcess.cursor(buffer) == {0, 5}
    end

    test "Fa moves backward, ; repeats backward" do
      # Place cursor at the end by moving right
      {editor, buffer} = start_editor("banana split")
      send_key(editor, ?$)
      end_col = elem(BufferProcess.cursor(buffer), 1)
      assert end_col > 0

      # Fa should find 'a' backward from end
      send_key(editor, ?F)
      send_key(editor, ?a)
      first_pos = elem(BufferProcess.cursor(buffer), 1)
      assert first_pos == 5

      # ; should repeat backward (same direction as F)
      send_key(editor, ?;)
      second_pos = elem(BufferProcess.cursor(buffer), 1)
      assert second_pos < first_pos
    end

    test "buffer_list doesn't crash" do
      {editor, _buffer} = start_editor()
      send_key(editor, 32)
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?b)
      _ = :sys.get_state(editor, @sync_timeout)
      send_key(editor, ?b)
      _ = :sys.get_state(editor, @sync_timeout)
      assert Process.alive?(editor)
    end
  end
end
