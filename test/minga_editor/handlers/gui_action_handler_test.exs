defmodule MingaEditor.Handlers.GuiActionHandlerTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Handlers.GuiActionHandler`.
  """

  use ExUnit.Case, async: true

  alias Minga.Events
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ResourcePressure
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  test "tab context actions target the requested tab without selecting it" do
    tab1 = Tab.new_file(1, "a.ex")
    tab2 = Tab.new_file(2, "b.ex")
    tab3 = Tab.new_file(3, "c.ex")
    tab_bar = %TabBar{tabs: [tab1, tab2, tab3], active_id: 1, next_id: 4}
    state = TestHelpers.base_state() |> EditorState.set_tab_bar(tab_bar)

    pinned = GuiActionHandler.dispatch(state, {:tab_pin, 3})
    pinned_tab_bar = EditorState.tab_bar(pinned)

    assert pinned_tab_bar.active_id == 1
    assert TabBar.get(pinned_tab_bar, 3).pinned?
    assert Enum.map(TabBar.visible_file_tabs(pinned_tab_bar), & &1.id) == [3, 1, 2]

    moved = GuiActionHandler.dispatch(pinned, {:tab_move_left, 2})
    moved_tab_bar = EditorState.tab_bar(moved)

    assert moved_tab_bar.active_id == 1
    assert Enum.map(TabBar.visible_file_tabs(moved_tab_bar), & &1.id) == [3, 2, 1]

    unpinned = GuiActionHandler.dispatch(moved, {:tab_unpin, 3})
    unpinned_tab_bar = EditorState.tab_bar(unpinned)

    assert unpinned_tab_bar.active_id == 1
    refute TabBar.get(unpinned_tab_bar, 3).pinned?
  end

  test "power thermal gui action updates resource pressure and broadcasts the event" do
    registry = power_thermal_events_registry()
    start_supervised!({Events, name: registry})
    Events.subscribe(:power_thermal_state_changed, registry: registry)

    state = %{TestHelpers.base_state() | events_registry: registry}

    assert {:ok, {:power_thermal_state, true, {:unknown, 255}}} =
             ProtocolGUI.decode_gui_action(0x47, <<1, 255>>)

    new_state = GuiActionHandler.dispatch(state, {:power_thermal_state, true, {:unknown, 255}})

    assert new_state.resource_pressure ==
             ResourcePressure.update(ResourcePressure.new(), true, {:unknown, 255})

    assert_receive {:minga_event, :power_thermal_state_changed,
                    %Events.PowerThermalStateEvent{
                      low_power?: true,
                      thermal_state: {:unknown, 255}
                    }}
  end

  defp power_thermal_events_registry do
    :"power_thermal_events_#{System.unique_integer([:positive])}"
  end
end
