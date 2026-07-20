defmodule Minga.Integration.GUIProtocolActionTest do
  @moduledoc false

  # async: false: owns the opt-in Swift harness that emits a synthetic gui_action.
  use ExUnit.Case, async: false

  alias Minga.Test.GUIHarness
  alias Minga.Frontend.Adapter.GUI.TabBarEncoder
  alias Minga.RenderModel.UI.TabBar
  alias Minga.RenderModel.UI.TabBar.Tab

  @harness_path Path.join(:code.priv_dir(:minga), "minga-test-harness")

  @moduletag :swift_harness

  setup_all do
    unless File.exists?(@harness_path) do
      flunk("Test harness not found at #{@harness_path}. Run: mix swift.harness")
    end

    {:ok, harness} = start_supervised({GUIHarness, path: @harness_path, emit_select_tab: true})
    %{harness: harness}
  end

  test "tab bar triggers an opted-in harness select_tab gui_action", %{harness: harness} do
    tab_bar = %TabBar{
      visible?: true,
      active_tab_id: 1,
      tabs: [
        %Tab{id: 1, workspace_id: 1, kind: :file, label: "main.ex", icon: ""},
        %Tab{id: 2, workspace_id: 1, kind: :file, label: "test.ex", icon: ""}
      ]
    }

    {decoded, action} =
      GUIHarness.round_trip_with_action!(
        harness,
        TabBarEncoder.encode_command(tab_bar),
        "gui_tab_bar",
        {:gui_action, {:select_tab, 2}}
      )

    assert Enum.count(decoded["tabs"]) == 2
    assert action == {:gui_action, {:select_tab, 2}}
  end
end
