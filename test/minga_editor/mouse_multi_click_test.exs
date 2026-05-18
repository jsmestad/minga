defmodule MingaEditor.MouseMultiClickTest do
  @moduledoc """
  Focused mouse gesture tests at the Mouse.handle/7 boundary.
  """

  # async: false because this file stubs the global clipboard mock for middle-click paste.
  use ExUnit.Case, async: false

  import Hammox

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Mouse
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState

  @gutter 6
  @content_row 1
  @shift 0x01

  setup :verify_on_exit!

  setup do
    stub(Minga.Clipboard.Mock, :read, fn -> nil end)
    :ok
  end

  describe "multi-click selection" do
    test "double-click selects the word under the cursor" do
      {state, buffer} = start_mouse_state("hello world foo")

      state = mouse(state, @content_row, @gutter + 6, :left, :press, 0, 2)

      assert editing_mode(state) == :visual
      assert state.workspace.editing.mode_state.visual_type == :char
      assert state.workspace.editing.mode_state.visual_anchor == {0, 6}
      assert BufferProcess.cursor(buffer) == {0, 10}
    end

    test "triple-click selects the clicked line" do
      {state, _buffer} = start_mouse_state("hello\nworld\nfoo")

      state = mouse(state, @content_row + 1, @gutter + 2, :left, :press, 0, 3)

      assert editing_mode(state) == :visual
      assert state.workspace.editing.mode_state.visual_type == :line
      assert state.workspace.editing.mode_state.visual_anchor == {1, 0}
    end
  end

  describe "modifier click selection" do
    test "shift-click from normal mode starts a visual selection from the existing cursor" do
      {state, buffer} = start_mouse_state("hello world foo bar")
      state = mouse(state, @content_row, @gutter, :left, :press)
      state = mouse(state, @content_row, @gutter, :left, :release)

      state = mouse(state, @content_row, @gutter + 10, :left, :press, @shift)

      assert editing_mode(state) == :visual
      assert state.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert BufferProcess.cursor(buffer) == {0, 10}
    end
  end

  describe "scrolling" do
    test "horizontal wheel events adjust the active viewport" do
      {state, _buffer} =
        start_mouse_state(
          "a very long line that extends beyond the viewport width for testing horizontal scroll"
        )

      state = mouse(state, @content_row, @gutter, :wheel_right, :press)
      assert active_viewport(state).left == 6

      state = mouse(state, @content_row, @gutter, :wheel_left, :press)
      assert active_viewport(state).left == 0
    end
  end

  describe "middle click" do
    test "middle-click moves the cursor to the clicked position" do
      {state, buffer} = start_mouse_state("hello world")

      mouse(state, @content_row, @gutter + 5, :middle, :press)

      assert BufferProcess.cursor(buffer) == {0, 5}
    end
  end

  describe "invalid coordinates" do
    test "negative coordinates are ignored" do
      {state, buffer} = start_mouse_state("hello")
      original = BufferProcess.cursor(buffer)

      state = mouse(state, -1, 5, :left, :press)
      assert BufferProcess.cursor(buffer) == original

      mouse(state, @content_row, -3, :left, :press)
      assert BufferProcess.cursor(buffer) == original
    end
  end

  defp start_mouse_state(content) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"#{__MODULE__}.Events.#{id}"
    project_root = Path.join(System.tmp_dir!(), "minga-mouse-multiclick-#{id}")
    File.mkdir_p!(project_root)
    start_supervised!({Minga.Events, name: events_registry}, id: {:events, id})

    options_server =
      start_supervised!({Minga.Config.Options, name: nil, events_registry: events_registry},
        id: {:options, id}
      )

    buffer =
      start_supervised!(
        {BufferProcess,
         content: content,
         filetype: :elixir,
         events_registry: events_registry,
         options_server: options_server},
        id: {:buffer, id}
      )

    state =
      Startup.build_initial_state(
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10,
        editing_model: :vim,
        options_server: options_server,
        events_registry: events_registry,
        project_root: project_root,
        suppress_tool_prompts: true
      )

    {state, buffer}
  end

  defp mouse(state, row, col, button, event_type, mods \\ 0, click_count \\ 1) do
    Mouse.handle(state, row, col, button, mods, event_type, click_count)
  end

  defp editing_mode(state), do: state.workspace.editing.mode

  defp active_viewport(state), do: EditorState.active_window_struct(state).viewport
end
