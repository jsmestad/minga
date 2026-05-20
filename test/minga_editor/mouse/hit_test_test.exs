defmodule MingaEditor.Mouse.HitTestTest do
  @moduledoc """
  Focused tests for resolving mouse screen coordinates to buffer targets.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias MingaEditor.Commands.Movement
  alias MingaEditor.Layout
  alias MingaEditor.Mouse.HitTest
  alias MingaEditor.Mouse.Target.Buffer, as: BufferTarget
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window

  describe "resolve_buffer/3" do
    test "resolves a single-window buffer target with gutter-adjusted columns" do
      {state, buffer} = start_mouse_state("zero\none\ntwo")
      %{content: {row, col, _width, _height}} = active_window_layout(state)
      gutter_width = HitTest.buffer_gutter_width(buffer, BufferProcess.line_count(buffer))

      assert {:buffer, %BufferTarget{} = target} =
               HitTest.resolve_buffer(state, row + 1, col + gutter_width + 2)

      assert target.window_id == state.workspace.windows.active
      assert target.buffer == buffer
      assert BufferTarget.position(target) == {1, 2}
      assert target.local_row == 1
      assert target.local_col == 2
      assert target.viewport == EditorState.active_window_struct(state).viewport
    end

    test "resolves split-window targets without stealing active-window context" do
      {state, _buffer} = start_mouse_state("zero\none\ntwo")
      state = Movement.execute(state, :split_vertical)
      active_id = state.workspace.windows.active
      layout = Layout.get(state)
      {target_id, %{content: {row, col, _width, _height}}} = rightmost_window_layout(layout)
      target_window = Map.fetch!(state.workspace.windows.map, target_id)

      gutter_width =
        HitTest.buffer_gutter_width(
          target_window.buffer,
          BufferProcess.line_count(target_window.buffer)
        )

      assert target_id != active_id

      assert {:buffer, %BufferTarget{} = target} =
               HitTest.resolve_buffer(state, row + 2, col + gutter_width + 1)

      assert target.window_id == target_id
      assert target.buffer == target_window.buffer
      assert BufferTarget.position(target) == {2, 1}
      assert state.workspace.windows.active == active_id
    end

    test "adds horizontal viewport offset to the resolved target column" do
      {state, buffer} = start_mouse_state("abcdefghijklmnopqrstuvwxyz")

      state =
        EditorState.update_window(
          state,
          state.workspace.windows.active,
          &Window.scroll_horizontal(&1, 5)
        )

      %{content: {row, col, _width, _height}} = active_window_layout(state)
      gutter_width = HitTest.buffer_gutter_width(buffer, BufferProcess.line_count(buffer))

      assert {:buffer, %BufferTarget{} = target} =
               HitTest.resolve_buffer(state, row, col + gutter_width + 3)

      assert BufferTarget.position(target) == {0, 8}
      assert target.local_col == 3
      assert target.viewport.left == 5
    end

    test "maps folded scrolled viewport rows back to buffer lines" do
      {state, buffer} = start_mouse_state(lines(0..49))

      state =
        EditorState.update_window(state, state.workspace.windows.active, fn window ->
          window
          |> Window.set_fold_ranges([FoldRange.new!(0, 2)])
          |> Window.fold_at(0)
          |> Window.scroll_viewport(1, BufferProcess.line_count(buffer))
        end)

      %{content: {row, col, _width, _height}} = active_window_layout(state)
      gutter_width = HitTest.buffer_gutter_width(buffer, BufferProcess.line_count(buffer))

      assert {:buffer, %BufferTarget{} = target} =
               HitTest.resolve_buffer(state, row, col + gutter_width)

      assert BufferTarget.position(target) == {3, 0}
    end

    test "returns miss outside buffer content" do
      {state, _buffer} = start_mouse_state("zero\none")

      assert HitTest.resolve_buffer(state, 999, 999) == :miss
    end
  end

  defp start_mouse_state(content, opts \\ []) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"#{__MODULE__}.Events.#{id}"
    project_root = Path.join(System.tmp_dir!(), "minga-hit-test-#{id}")
    File.mkdir_p!(project_root)
    start_supervised!({Minga.Events, name: events_registry}, id: {:events, id})

    options_server =
      start_supervised!({Minga.Config.Options, name: nil, events_registry: events_registry},
        id: {:options, id}
      )

    buffer =
      start_supervised!(
        {BufferProcess,
         content: content, events_registry: events_registry, options_server: options_server},
        id: {:buffer, id}
      )

    state =
      Startup.build_initial_state(
        port_manager: nil,
        buffer: buffer,
        width: Keyword.get(opts, :width, 40),
        height: Keyword.get(opts, :height, 10),
        editing_model: :vim,
        options_server: options_server,
        events_registry: events_registry,
        project_root: project_root,
        suppress_tool_prompts: true
      )

    {state, buffer}
  end

  defp active_window_layout(state), do: Layout.active_window_layout(Layout.get(state), state)

  defp lines(range), do: Enum.map_join(range, "\n", &"line #{&1}")

  defp rightmost_window_layout(layout) do
    Enum.max_by(layout.window_layouts, fn {_id, %{content: {_row, content_col, _width, _height}}} ->
      content_col
    end)
  end
end
