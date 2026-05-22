defmodule MingaEditor.MergeConflict.RenderTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias MingaEditor.BufferDecorations
  alias MingaEditor.Layout
  alias MingaEditor.Mouse
  alias MingaEditor.Mouse.HitTest
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  test "composes highlight and action block decorations for conflict markers" do
    buffer = start_supervised!({BufferProcess, [content: conflict_content()]})

    decorations = BufferDecorations.compose(%{}, buffer)

    assert [_marker] = Decorations.highlights_for_line(decorations, 0)
    assert [_current] = Decorations.highlights_for_line(decorations, 1)
    assert [_separator] = Decorations.highlights_for_line(decorations, 2)
    assert [_incoming] = Decorations.highlights_for_line(decorations, 3)
    assert [_end_marker] = Decorations.highlights_for_line(decorations, 4)

    assert {[block], []} = Decorations.blocks_for_line(decorations, 0)
    rendered = block.render.(80)
    assert [{" ", _face}, {"Accept Current", _face2} | _rest] = rendered

    %{
      current: current,
      current_separator: current_separator,
      incoming: incoming,
      incoming_separator: incoming_separator,
      both: both,
      trailing: trailing
    } =
      action_row_columns(rendered)

    assert {:command, {:git_accept_conflict, :current, 0}} = block.on_click.(0, current.start)
    assert {:command, {:git_accept_conflict, :current, 0}} = block.on_click.(0, current.stop)
    assert :ok = block.on_click.(0, current_separator.start)
    assert :ok = block.on_click.(0, current_separator.stop)

    assert {:command, {:git_accept_conflict, :incoming, 0}} = block.on_click.(0, incoming.start)
    assert {:command, {:git_accept_conflict, :incoming, 0}} = block.on_click.(0, incoming.stop)
    assert :ok = block.on_click.(0, incoming_separator.start)
    assert :ok = block.on_click.(0, incoming_separator.stop)

    assert {:command, {:git_accept_conflict, :both, 0}} = block.on_click.(0, both.start)
    assert {:command, {:git_accept_conflict, :both, 0}} = block.on_click.(0, both.stop)
    assert :ok = block.on_click.(0, trailing.start)
  end

  test "hit-testing conflict action blocks returns the accept command" do
    buffer = start_supervised!({BufferProcess, [content: conflict_content()]})
    state = state_with_buffer(buffer)

    %{content: {row, col, _width, _height}} =
      Layout.active_window_layout(Layout.get(state), state)

    gutter_width = HitTest.buffer_gutter_width(buffer, BufferProcess.line_count(buffer))

    assert {:command, {:git_accept_conflict, :current, 0}} =
             HitTest.resolve_buffer(state, row, col + gutter_width + 1)
  end

  test "mouse click on action block dispatches the accept command" do
    buffer = start_supervised!({BufferProcess, [content: conflict_content()]})
    state = state_with_buffer(buffer)

    %{content: {row, col, _width, _height}} =
      Layout.active_window_layout(Layout.get(state), state)

    gutter_width = HitTest.buffer_gutter_width(buffer, BufferProcess.line_count(buffer))

    state = Mouse.handle(state, row, col + gutter_width + 1, :left, 0, :press, 1)

    assert BufferProcess.content(buffer) == "ours"
    assert state.shell_state.status_msg == "Resolved all merge conflicts"
  end

  test "mouse click on action block separators is a no-op" do
    buffer = start_supervised!({BufferProcess, [content: conflict_content()]})
    state = state_with_buffer(buffer)
    before_content = BufferProcess.content(buffer)
    before_cursor = BufferProcess.cursor(buffer)

    decorations = BufferDecorations.compose(%{}, buffer)
    assert {[block], []} = Decorations.blocks_for_line(decorations, 0)

    %{current_separator: separator} = action_row_columns(block.render.(80))

    %{content: {row, col, _width, _height}} =
      Layout.active_window_layout(Layout.get(state), state)

    gutter_width = HitTest.buffer_gutter_width(buffer, BufferProcess.line_count(buffer))
    screen_col = col + gutter_width + separator.start

    assert :block_noop = HitTest.resolve_buffer(state, row, screen_col)

    state = Mouse.handle(state, row, screen_col, :left, 0, :press, 1)

    assert BufferProcess.content(buffer) == before_content
    assert BufferProcess.cursor(buffer) == before_cursor
    assert state.shell_state.status_msg == nil
  end

  test "hit-testing action blocks uses visible columns when horizontally scrolled" do
    buffer = start_supervised!({BufferProcess, [content: conflict_content()]})
    state = state_with_buffer(buffer, viewport_left: 20)

    %{content: {row, col, _width, _height}} =
      Layout.active_window_layout(Layout.get(state), state)

    gutter_width = HitTest.buffer_gutter_width(buffer, BufferProcess.line_count(buffer))

    assert {:command, {:git_accept_conflict, :current, 0}} =
             HitTest.resolve_buffer(state, row, col + gutter_width + 1)
  end

  defp state_with_buffer(buffer, opts \\ []) do
    viewport_left = Keyword.get(opts, :viewport_left, 0)
    window = Window.new(1, buffer, 24, 80)
    window = %{window | viewport: %{window.viewport | left: viewport_left}}

    %EditorState{
      port_manager: self(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{list: [buffer], active_index: 0, active: buffer},
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      shell_state: %ShellState{}
    }
  end

  @spec action_row_columns([{String.t(), term()}]) :: %{
          current: %{start: non_neg_integer(), stop: non_neg_integer()},
          current_separator: %{start: non_neg_integer(), stop: non_neg_integer()},
          incoming: %{start: non_neg_integer(), stop: non_neg_integer()},
          incoming_separator: %{start: non_neg_integer(), stop: non_neg_integer()},
          both: %{start: non_neg_integer(), stop: non_neg_integer()},
          trailing: %{start: non_neg_integer(), stop: non_neg_integer()}
        }
  defp action_row_columns(rendered) do
    [leading, current, current_separator, incoming, incoming_separator, both, trailing] =
      Enum.map(rendered, fn {text, _face} -> String.length(text) end)

    current_start = leading
    current_stop = current_start + current - 1
    current_separator_start = current_stop + 1
    current_separator_stop = current_separator_start + current_separator - 1
    incoming_start = current_separator_stop + 1
    incoming_stop = incoming_start + incoming - 1
    incoming_separator_start = incoming_stop + 1
    incoming_separator_stop = incoming_separator_start + incoming_separator - 1
    both_start = incoming_separator_stop + 1
    both_stop = both_start + both - 1
    trailing_start = both_stop + 1
    trailing_stop = trailing_start + trailing - 1

    %{
      current: %{start: current_start, stop: current_stop},
      current_separator: %{start: current_separator_start, stop: current_separator_stop},
      incoming: %{start: incoming_start, stop: incoming_stop},
      incoming_separator: %{start: incoming_separator_start, stop: incoming_separator_stop},
      both: %{start: both_start, stop: both_stop},
      trailing: %{start: trailing_start, stop: trailing_stop}
    }
  end

  defp conflict_content do
    "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch"
  end
end
