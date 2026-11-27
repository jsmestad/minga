defmodule MingaEditor.Handlers.CommandOutputRedrawTest do
  # async: false: spawns an OS process through a Port, which races with concurrent Port teardown.
  use ExUnit.Case, async: false

  @moduletag :heavy

  alias Minga.CommandOutput
  alias Minga.Events
  alias Minga.Events.BufferChangedEvent
  alias MingaEditor.Handlers.FileEventHandler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Windows
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    registry = :"command_output_redraw_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: registry})
    Events.subscribe(:buffer_changed, registry: registry)
    Events.subscribe(:command_done, registry: registry)

    name = "redraw_output_#{System.unique_integer([:positive])}"
    :ok = CommandOutput.run(name, "printf 'one\\ntwo\\n'", events_registry: registry)
    buffer = CommandOutput.buffer(name)

    # Output chunks are the only changes that carry an edit delta from an unknown writer.
    assert_receive {:minga_event, :buffer_changed,
                    %BufferChangedEvent{buffer: ^buffer, source: :unknown, delta: %{}} = chunk},
                   2000

    assert_receive {:minga_event, :command_done, %Events.CommandDoneEvent{name: ^name}}, 2000

    %{buffer: buffer, chunk: chunk}
  end

  test "an output chunk schedules a frame when a window shows the output buffer", ctx do
    state = show_in_window(base_state(), ctx.buffer)

    assert {_state, [{:render, 16}]} =
             FileEventHandler.handle(state, {:minga_event, :buffer_changed, ctx.chunk})
  end

  test "an output chunk schedules no frame when no window shows the output buffer", ctx do
    assert {_state, []} =
             FileEventHandler.handle(base_state(), {:minga_event, :buffer_changed, ctx.chunk})
  end

  defp show_in_window(state, buffer) do
    {id, windows} = Windows.allocate_id(state.workspace.windows)
    windows = Windows.add_window(windows, Window.new(id, buffer, 10, 80))
    %{state | workspace: SessionState.set_windows(state.workspace, windows)}
  end
end
