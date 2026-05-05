defmodule MingaEditor.State.EventsRegistryThreadingTest do
  @moduledoc """
  Integration tests that prove `EditorState.events_registry` is honored by the event bus boundary.
  """
  use ExUnit.Case, async: true

  alias Minga.Events
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias Minga.Mode

  defp build_state(events_registry) do
    %EditorState{
      port_manager: self(),
      events_registry: events_registry,
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        editing: %VimState{mode: :normal, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: nil, list: []}
      }
    }
  end

  test "EditorState.events_registry isolates event delivery between registries" do
    registry_a = :events_registry_threading_a
    registry_b = :events_registry_threading_b
    start_supervised!({Events, name: registry_a})
    start_supervised!({Events, name: registry_b})

    state_a = build_state(registry_a)
    state_b = build_state(registry_b)
    assert EditorState.events_registry(state_a) == registry_a
    assert EditorState.events_registry(state_b) == registry_b

    Events.subscribe(:log_message, EditorState.events_registry(state_a))

    Events.broadcast(
      :log_message,
      %Events.LogMessageEvent{text: "wrong registry", level: :info},
      EditorState.events_registry(state_b)
    )

    refute_receive {:minga_event, :log_message, _}, 50

    Events.broadcast(
      :log_message,
      %Events.LogMessageEvent{text: "right registry", level: :info},
      EditorState.events_registry(state_a)
    )

    assert_receive {:minga_event, :log_message, %Events.LogMessageEvent{text: "right registry"}}
  end

  test "EditorState defaults events_registry to Minga.Events.default_registry/0" do
    state = %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        editing: %VimState{mode: :normal, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: nil, list: []}
      }
    }

    assert EditorState.events_registry(state) == Events.default_registry()
  end
end
