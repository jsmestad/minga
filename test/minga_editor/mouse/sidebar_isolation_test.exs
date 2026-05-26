defmodule MingaEditor.Mouse.SidebarIsolationTest do
  @moduledoc """
  Regression tests for mouse coordinate isolation from the global sidebar registry.
  """

  # Mutates the default sidebar registry intentionally; private state must still drive mouse hit testing.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.Mouse
  alias MingaEditor.Startup

  @source {:extension, :mouse_sidebar_isolation_test}

  setup do
    Sidebar.unregister_source(@source)
    on_exit(fn -> Sidebar.unregister_source(@source) end)
    :ok
  end

  test "double-click hit testing ignores polluted default sidebar registry" do
    {state, buffer} = start_mouse_state("hello world")
    {row, col} = buffer_screen_pos(state, 0, 4)

    assert :ok =
             Sidebar.register(@source, %{
               id: "mouse_isolation_sidebar",
               display_name: "Mouse Isolation",
               placement: :left,
               preferred_width: 20,
               visible?: true,
               focused?: true
             })

    state = Mouse.handle(state, row, col, :left, 0, :press, 2)

    assert BufferProcess.cursor(buffer) == {0, 4}
    assert state.workspace.editing.mode == :visual
    assert state.workspace.editing.mode_state.visual_anchor == {0, 0}
  end

  defp start_mouse_state(content) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"#{__MODULE__}.Events.#{id}"
    sidebar_registry = Module.concat(__MODULE__, "Sidebar#{id}")
    project_root = Path.join(System.tmp_dir!(), "minga-mouse-sidebar-isolation-#{id}")
    File.mkdir_p!(project_root)
    start_supervised!({Minga.Events, name: events_registry}, id: {:events, id})
    start_supervised!({Sidebar, name: sidebar_registry, notify: false}, id: {:sidebars, id})

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
        width: 40,
        height: 10,
        editing_model: :vim,
        options_server: options_server,
        events_registry: events_registry,
        sidebar_registry: sidebar_registry,
        project_root: project_root,
        suppress_tool_prompts: true
      )

    {state, buffer}
  end

  defp buffer_screen_pos(state, buffer_line, buffer_col) do
    %{content: {content_row, content_col, _width, _height}} =
      Layout.active_window_layout(Layout.get(state), state)

    buffer = state.workspace.buffers.active
    total_lines = BufferProcess.line_count(buffer)
    gutter_width = MingaEditor.Mouse.HitTest.buffer_gutter_width(buffer, total_lines)

    {content_row + buffer_line, content_col + gutter_width + buffer_col}
  end
end
