defmodule MingaEditor.Frontend.Emit.GUI.ChromeCacheTest do
  @moduledoc """
  Tests for fingerprint-based change detection in `sync_swiftui_chrome/4`.

  Verifies that unchanged chrome components are skipped on subsequent
  frames, and that changed components are re-sent. Inspects the returned
  `Caches` struct rather than the process dictionary.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.Caches
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Emit.GUI, as: EmitGUI

  import MingaEditor.RenderPipeline.TestHelpers

  defp flush_port_casts do
    receive do
      {:"$gen_cast", {:send_commands, _}} -> flush_port_casts()
    after
      0 -> :ok
    end
  end

  defp collect_port_casts do
    collect_port_casts([])
  end

  defp collect_port_casts(acc) do
    receive do
      {:"$gen_cast", {:send_commands, cmds}} -> collect_port_casts([cmds | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "sync_swiftui_chrome/4 fingerprint caching" do
    test "sends chrome commands on first call" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      casts = collect_port_casts()
      assert casts != [], "expected at least one port cast on first call"

      all_cmds = List.flatten(casts)
      assert all_cmds != []
    end

    test "skips unchanged chrome on second call with identical state" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      # First call: populates caches.
      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      # Second call with the same state and populated caches: only status bar should be sent.
      EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, caches)
      casts = collect_port_casts()

      assert length(casts) == 1, "expected exactly one port cast (status bar always sent)"

      all_cmds = List.flatten(casts)

      status_bar_cmds =
        Enum.filter(all_cmds, fn
          <<0x76, _::binary>> -> true
          _ -> false
        end)

      assert length(status_bar_cmds) == 1,
             "expected exactly one status bar command on unchanged second call"

      assert length(all_cmds) == 1,
             "expected only status bar command on second call, got #{length(all_cmds)} commands"
    end

    test "re-sends chrome when state changes between calls" do
      state = gui_state(content: long_content(50))
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      changed_state = %{state | theme: MingaEditor.UI.Theme.get!(:one_dark)}
      sb_data2 = StatusBarData.from_state(changed_state)

      EmitGUI.sync_swiftui_chrome(Context.from_editor_state(changed_state), sb_data2, nil, caches)
      casts = collect_port_casts()

      all_cmds = List.flatten(casts)

      theme_cmds =
        Enum.filter(all_cmds, fn
          <<0x74, _::binary>> -> true
          _ -> false
        end)

      assert length(theme_cmds) == 1, "expected theme command after theme change"
      assert length(all_cmds) > 1, "expected more than just status bar after theme change"
    end

    test "file tree cache key is populated after first call" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      caches0 = %Caches{}
      assert caches0.last_gui_file_tree_fp == nil

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, caches0)

      flush_port_casts()

      assert caches.last_gui_file_tree_fp == :no_tree
    end

    test "picker cache tracks closed state" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      assert caches.last_gui_picker_fp == :closed
    end

    test "agent chat cache tracks not-visible state" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      assert caches.last_gui_agent_chat_fp == :not_visible
    end

    test "bottom panel returns updated context" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      {ctx, _caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      assert is_map(ctx)
      assert Map.has_key?(ctx, :message_store)
    end

    test "picker cache fingerprints an open picker without crashing" do
      item = %MingaEditor.UI.Picker.Item{id: "a", label: "a.txt"}
      picker = MingaEditor.UI.Picker.new([item], title: "Test")
      state = gui_state()

      picker_state = %MingaEditor.State.Picker{picker: picker, source: nil, action_menu: nil}
      state = ModalOverlay.open(state, :picker, PickerPayload.new(picker_state))
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      refute caches.last_gui_picker_fp in [:closed, nil]
    end

    test "agent chat survives dead prompt buffer process" do
      state = gui_state()

      {:ok, dead_pid} = Agent.start(fn -> nil end)
      Agent.stop(dead_pid)

      panel = %{state.workspace.agent_ui.panel | prompt_buffer: dead_pid}

      state = %{
        state
        | workspace: %{state.workspace | agent_ui: %{state.workspace.agent_ui | panel: panel}}
      }

      sb_data = StatusBarData.from_state(state)

      {ctx, _caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      assert is_map(ctx)
    end
  end
end
