defmodule Minga.Editor.RenderPipeline.Emit.GUI.ChromeCacheTest do
  @moduledoc """
  Tests for fingerprint-based change detection in `sync_swiftui_chrome/3`.

  Verifies that unchanged chrome components are skipped on subsequent
  frames, and that changed components are re-sent. Uses the process
  dictionary cache keys directly since `sync_swiftui_chrome` stores
  fingerprints there.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.RenderPipeline.Emit.GUI, as: EmitGUI
  alias Minga.Editor.StatusBar.Data, as: StatusBarData

  import Minga.Editor.RenderPipeline.TestHelpers

  # Process dictionary keys used by the caching logic.
  @cache_keys [
    :last_gui_theme,
    :last_gui_tab_bar_fp,
    :last_gui_file_tree_fp,
    :last_gui_which_key_fp,
    :last_gui_completion_fp,
    :last_gui_breadcrumb_fp,
    :last_gui_picker_fp,
    :last_gui_agent_chat_fp,
    :last_gui_bottom_panel_fp,
    :last_gui_minibuffer,
    # Also clear the font registry that Emit puts in the process dict.
    :emit_font_registry
  ]

  setup do
    # Clear all cache keys so each test starts from a cold cache.
    for key <- @cache_keys, do: Process.delete(key)
    :ok
  end

  defp gui_chrome_state(opts \\ []) do
    state = gui_state(opts)
    # Ensure font registry is set (emit_gui expects this).
    Process.put(:emit_font_registry, state.font_registry)
    state
  end

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

  describe "sync_swiftui_chrome/3 fingerprint caching" do
    test "sends chrome commands on first call" do
      state = gui_chrome_state()
      sb_data = StatusBarData.from_state(state)

      EmitGUI.sync_swiftui_chrome(state, sb_data)

      # Should receive at least one send_commands cast with chrome data.
      casts = collect_port_casts()
      assert casts != [], "expected at least one port cast on first call"

      # The batched commands should contain multiple opcodes.
      all_cmds = List.flatten(casts)
      assert all_cmds != []
    end

    test "skips unchanged chrome on second call with identical state" do
      state = gui_chrome_state()
      sb_data = StatusBarData.from_state(state)

      # First call: populates caches.
      EmitGUI.sync_swiftui_chrome(state, sb_data)
      flush_port_casts()

      # Second call with the same state: only status bar should be sent
      # (it has no caching since cursor position changes every frame).
      EmitGUI.sync_swiftui_chrome(state, sb_data)
      casts = collect_port_casts()

      # Status bar always returns a binary (no fingerprint cache), so
      # chrome_cmds is never empty and we always get exactly one cast.
      assert length(casts) == 1, "expected exactly one port cast (status bar always sent)"

      all_cmds = List.flatten(casts)

      # On second call, only status bar (always sent) should be in the batch.
      # All other chrome should be skipped. The status bar opcode is 0x76.
      status_bar_cmds =
        Enum.filter(all_cmds, fn
          <<0x76, _::binary>> -> true
          _ -> false
        end)

      assert length(status_bar_cmds) == 1,
             "expected exactly one status bar command on unchanged second call"

      # Total commands should be exactly 1 (just the status bar).
      assert length(all_cmds) == 1,
             "expected only status bar command on second call, got #{length(all_cmds)} commands"
    end

    test "re-sends chrome when state changes between calls" do
      state = gui_chrome_state(content: long_content(50))
      sb_data = StatusBarData.from_state(state)

      # First call to populate caches.
      EmitGUI.sync_swiftui_chrome(state, sb_data)
      flush_port_casts()

      # Change the theme to force a cache miss on the theme fingerprint.
      changed_state = %{state | theme: Minga.UI.Theme.get!(:one_dark)}
      sb_data2 = StatusBarData.from_state(changed_state)

      EmitGUI.sync_swiftui_chrome(changed_state, sb_data2)
      casts = collect_port_casts()

      all_cmds = List.flatten(casts)

      # Should have more than just the status bar since theme changed.
      # Theme opcode is 0x74.
      theme_cmds =
        Enum.filter(all_cmds, fn
          <<0x74, _::binary>> -> true
          _ -> false
        end)

      assert length(theme_cmds) == 1, "expected theme command after theme change"
      assert length(all_cmds) > 1, "expected more than just status bar after theme change"
    end

    test "file tree cache key is populated after first call" do
      state = gui_chrome_state()
      sb_data = StatusBarData.from_state(state)

      assert Process.get(:last_gui_file_tree_fp) == nil

      EmitGUI.sync_swiftui_chrome(state, sb_data)
      flush_port_casts()

      # After first call, the file tree cache should be set.
      # Since there's no file tree in the test state, it should be :no_tree.
      assert Process.get(:last_gui_file_tree_fp) == :no_tree
    end

    test "picker cache tracks closed state" do
      state = gui_chrome_state()
      sb_data = StatusBarData.from_state(state)

      # No picker is open in the test state.
      EmitGUI.sync_swiftui_chrome(state, sb_data)
      flush_port_casts()

      assert Process.get(:last_gui_picker_fp) == :closed
    end

    test "agent chat cache tracks not-visible state" do
      state = gui_chrome_state()
      sb_data = StatusBarData.from_state(state)

      EmitGUI.sync_swiftui_chrome(state, sb_data)
      flush_port_casts()

      assert Process.get(:last_gui_agent_chat_fp) == :not_visible
    end

    test "bottom panel returns updated state" do
      state = gui_chrome_state()
      sb_data = StatusBarData.from_state(state)

      # sync_swiftui_chrome returns the updated state (for message_store).
      new_state = EmitGUI.sync_swiftui_chrome(state, sb_data)
      flush_port_casts()

      assert is_map(new_state)
      assert Map.has_key?(new_state, :message_store)
    end

    test "picker cache fingerprints an open picker without crashing" do
      item = %Minga.Picker.Item{id: "a", label: "a.txt"}
      picker = Minga.Picker.new([item], title: "Test")
      state = gui_chrome_state()

      # Inject an open picker into picker_ui state.
      picker_ui = %{state.picker_ui | picker: picker, source: nil, action_menu: nil}
      state = %{state | picker_ui: picker_ui}
      sb_data = StatusBarData.from_state(state)

      # Before the fix, this raised KeyError: key :total not found in %Minga.Picker{}.
      EmitGUI.sync_swiftui_chrome(state, sb_data)
      flush_port_casts()

      refute Process.get(:last_gui_picker_fp) in [:closed, nil]
    end

    test "agent chat survives dead prompt buffer process" do
      state = gui_chrome_state()

      # Start and immediately stop a process to get a dead pid.
      {:ok, dead_pid} = Agent.start(fn -> nil end)
      Agent.stop(dead_pid)

      # Inject the dead pid as the prompt buffer in agent_ui state.
      panel = %{state.workspace.agent_ui.panel | prompt_buffer: dead_pid}

      state = %{
        state
        | workspace: %{state.workspace | agent_ui: %{state.workspace.agent_ui | panel: panel}}
      }

      sb_data = StatusBarData.from_state(state)

      # Should not crash; the dead buffer is handled via catch :exit.
      new_state = EmitGUI.sync_swiftui_chrome(state, sb_data)
      flush_port_casts()

      assert is_map(new_state)
    end
  end
end
