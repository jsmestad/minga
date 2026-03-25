defmodule Minga.Popup.LifecycleTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Popup.Lifecycle
  alias Minga.Popup.Registry, as: PopupRegistry
  alias Minga.Popup.Rule

  # Lightweight fake buffer pid that responds to GenServer.call(:display_name)
  # so Layout.compute doesn't hang for 5 seconds on a default timeout.
  defp fake_pid do
    spawn(fn -> fake_pid_loop() end)
  end

  defp fake_pid_loop do
    receive do
      {:"$gen_call", from, :display_name} ->
        GenServer.reply(from, "[test]")
        fake_pid_loop()

      _ ->
        fake_pid_loop()
    end
  end

  setup do
    # Each test gets its own popup registry table (async-safe)
    table = :"popup_lifecycle_#{:erlang.unique_integer([:positive])}"
    PopupRegistry.init(table)

    main_buf = fake_pid()
    popup_buf = fake_pid()

    main_window = Window.new(1, main_buf, 24, 80)

    state = %EditorState{
      port_manager: nil,
      viewport: Viewport.new(24, 80),
      vim: VimState.new(),
      buffers: %Buffers{active: main_buf, list: [main_buf]},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => main_window},
        active: 1,
        next_id: 2
      }
    }

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)

      for pid <- [main_buf, popup_buf] do
        Process.exit(pid, :kill)
      end
    end)

    %{state: state, main_buf: main_buf, popup_buf: popup_buf, table: table}
  end

  describe "open_popup/3" do
    test "returns :no_match when no rule matches", %{state: state, popup_buf: popup_buf, table: t} do
      assert :no_match = Lifecycle.open_popup(state, "unknown-buffer", popup_buf, registry: t)
    end

    test "creates a bottom split popup when rule matches", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Warnings*", side: :bottom, size: {:percent, 30}), t)

      assert {:ok, new_state} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)

      # A new window should exist
      assert map_size(new_state.windows.map) == 2
      assert new_state.windows.next_id == 3

      # The new window should have popup metadata
      popup_window = Map.get(new_state.windows.map, 2)
      assert popup_window != nil
      assert Window.popup?(popup_window)
      assert popup_window.popup_meta.rule.side == :bottom
      assert popup_window.popup_meta.previous_active == 1

      # The tree should be a horizontal split
      assert {:split, :horizontal, _, _, _} = new_state.windows.tree
    end

    test "creates a right split popup", %{state: state, popup_buf: popup_buf, table: t} do
      PopupRegistry.register(Rule.new("*Warnings*", side: :right, size: {:percent, 40}), t)

      assert {:ok, new_state} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)

      assert {:split, :vertical, _, _, _} = new_state.windows.tree
    end

    test "focuses the popup when rule.focus is true", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Warnings*", focus: true), t)

      assert {:ok, new_state} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)
      assert new_state.windows.active == 2
    end

    test "keeps focus on original window when rule.focus is false", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Warnings*", focus: false), t)

      assert {:ok, new_state} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)
      assert new_state.windows.active == 1
    end

    test "invalidates layout cache after opening", %{state: state, popup_buf: popup_buf, table: t} do
      PopupRegistry.register(Rule.new("*Warnings*"), t)

      # Pre-compute layout
      state = %{state | layout: Layout.compute(state)}
      assert %Layout{} = state.layout

      assert {:ok, new_state} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)
      assert is_nil(new_state.layout)
    end
  end

  describe "close_popup/2" do
    test "restores the original tree", %{state: state, popup_buf: popup_buf, table: t} do
      PopupRegistry.register(Rule.new("*Warnings*", side: :bottom), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)

      # Close the popup
      restored = Lifecycle.close_popup(with_popup, 2)

      # Tree should be back to a single leaf
      assert {:leaf, 1} = restored.windows.tree

      # Popup window should be removed from the map
      assert map_size(restored.windows.map) == 1
      assert Map.has_key?(restored.windows.map, 1)
      refute Map.has_key?(restored.windows.map, 2)
    end

    test "restores focus to the previously active window", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Warnings*", focus: true), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)

      # Focus is on the popup
      assert with_popup.windows.active == 2

      # Close restores focus to window 1
      restored = Lifecycle.close_popup(with_popup, 2)
      assert restored.windows.active == 1
    end

    test "is a no-op for non-popup windows", %{state: state, table: _t} do
      result = Lifecycle.close_popup(state, 1)
      assert result.windows.tree == state.windows.tree
    end

    test "is a no-op for nonexistent window ids", %{state: state, table: _t} do
      result = Lifecycle.close_popup(state, 999)
      assert result.windows.tree == state.windows.tree
    end

    test "invalidates layout cache after closing", %{state: state, popup_buf: popup_buf, table: t} do
      PopupRegistry.register(Rule.new("*Warnings*"), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)

      # Set a layout cache
      with_popup = %{with_popup | layout: Layout.compute(with_popup)}
      assert %Layout{} = with_popup.layout

      restored = Lifecycle.close_popup(with_popup, 2)
      assert is_nil(restored.layout)
    end
  end

  describe "close_active_popup/1" do
    test "closes the active popup", %{state: state, popup_buf: popup_buf, table: t} do
      PopupRegistry.register(Rule.new("*Warnings*", focus: true), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)

      assert with_popup.windows.active == 2

      restored = Lifecycle.close_active_popup(with_popup)
      assert {:leaf, 1} = restored.windows.tree
      assert restored.windows.active == 1
    end

    test "is a no-op when active window is not a popup", %{state: state, table: _t} do
      result = Lifecycle.close_active_popup(state)
      assert result.windows.tree == state.windows.tree
    end
  end

  describe "closing one popup preserves other popups" do
    test "closing the first-opened popup does not clobber the second", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      popup_buf2 = fake_pid()
      on_exit(fn -> Process.exit(popup_buf2, :kill) end)

      PopupRegistry.register(Rule.new("*Messages*", side: :bottom, size: {:percent, 25}), t)
      PopupRegistry.register(Rule.new("*Warnings*", side: :bottom, size: {:percent, 30}), t)

      # Open both popups
      {:ok, with_messages} = Lifecycle.open_popup(state, "*Messages*", popup_buf, registry: t)

      {:ok, with_both} =
        Lifecycle.open_popup(with_messages, "*Warnings*", popup_buf2, registry: t)

      # Should have 3 windows: main + Messages + Warnings
      assert map_size(with_both.windows.map) == 3

      # Close Messages (the first-opened popup, window 2)
      after_close = Lifecycle.close_popup(with_both, 2)

      # Warnings popup (window 3) should still exist
      assert map_size(after_close.windows.map) == 2
      assert Map.has_key?(after_close.windows.map, 1), "main window missing"
      assert Map.has_key?(after_close.windows.map, 3), "Warnings popup was clobbered"

      # Window 3 should still be in the tree
      leaves = WindowTree.leaves(after_close.windows.tree)
      assert 3 in leaves, "Warnings popup window not in tree"
    end

    test "closing the second-opened popup does not affect the first", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      popup_buf2 = fake_pid()
      on_exit(fn -> Process.exit(popup_buf2, :kill) end)

      PopupRegistry.register(Rule.new("*Messages*", side: :bottom, size: {:percent, 25}), t)
      PopupRegistry.register(Rule.new("*Warnings*", side: :bottom, size: {:percent, 30}), t)

      {:ok, with_messages} = Lifecycle.open_popup(state, "*Messages*", popup_buf, registry: t)

      {:ok, with_both} =
        Lifecycle.open_popup(with_messages, "*Warnings*", popup_buf2, registry: t)

      # Close Warnings (the second-opened popup, window 3)
      after_close = Lifecycle.close_popup(with_both, 3)

      # Messages popup (window 2) should still exist
      assert map_size(after_close.windows.map) == 2
      assert Map.has_key?(after_close.windows.map, 1), "main window missing"
      assert Map.has_key?(after_close.windows.map, 2), "Messages popup was clobbered"

      leaves = WindowTree.leaves(after_close.windows.tree)
      assert 2 in leaves, "Messages popup window not in tree"
    end
  end

  describe "close_all_popups/1" do
    test "closes all popup windows", %{state: state, popup_buf: popup_buf, table: t} do
      PopupRegistry.register(Rule.new("*Warnings*", focus: false), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)

      # Verify popup exists
      assert map_size(with_popup.windows.map) == 2

      restored = Lifecycle.close_all_popups(with_popup)
      assert {:leaf, 1} = restored.windows.tree
      assert map_size(restored.windows.map) == 1
    end

    test "is a no-op when no popups are open", %{state: state, table: _t} do
      result = Lifecycle.close_all_popups(state)
      assert result.windows.tree == state.windows.tree
    end
  end

  describe "active_is_popup?/1" do
    test "returns false when active window is not a popup", %{state: state, table: _t} do
      refute Lifecycle.active_is_popup?(state)
    end

    test "returns true when active window is a popup", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Warnings*", focus: true), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)

      assert Lifecycle.active_is_popup?(with_popup)
    end
  end

  describe "float display mode" do
    test "float popup adds window to map but not tree", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Help*", display: :float, focus: true), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Help*", popup_buf, registry: t)

      # Window map has 2 entries (main + popup)
      assert map_size(with_popup.windows.map) == 2

      # Tree still only has the original leaf (no split was created)
      assert with_popup.windows.tree == WindowTree.new(1)
    end

    test "float popup focuses the new window when focus: true", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Help*", display: :float, focus: true), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Help*", popup_buf, registry: t)

      assert with_popup.windows.active == 2
    end

    test "float popup does not steal focus when focus: false", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Help*", display: :float, focus: false), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Help*", popup_buf, registry: t)

      assert with_popup.windows.active == 1
    end

    test "closing a float popup removes window and restores focus", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Help*", display: :float, focus: true), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Help*", popup_buf, registry: t)

      restored = Lifecycle.close_popup(with_popup, 2)

      assert map_size(restored.windows.map) == 1
      assert restored.windows.active == 1
      assert restored.windows.tree == WindowTree.new(1)
    end

    test "float popup has popup_meta with the rule", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Help*", display: :float, border: :double), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Help*", popup_buf, registry: t)

      popup_window = with_popup.windows.map[2]
      assert Window.popup?(popup_window)
      assert popup_window.popup_meta.rule.display == :float
      assert popup_window.popup_meta.rule.border == :double
    end

    test "render_float_overlays returns overlays for float popups", %{state: state, table: t} do
      real_buf =
        start_supervised!(
          {BufferServer, content: "hello world", buffer_name: "*Help*"},
          id: :float_overlay_buf
        )

      PopupRegistry.register(Rule.new("*Help*", display: :float, focus: true), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Help*", real_buf, registry: t)

      overlays = Lifecycle.render_float_overlays(with_popup)
      assert length(overlays) == 1
      [overlay] = overlays
      assert is_list(overlay.draws)
      assert overlay.draws != []
    end

    test "render_float_overlays returns empty for split-only popups", %{
      state: state,
      popup_buf: popup_buf,
      table: t
    } do
      PopupRegistry.register(Rule.new("*Warnings*", display: :split, side: :bottom), t)
      {:ok, with_popup} = Lifecycle.open_popup(state, "*Warnings*", popup_buf, registry: t)

      overlays = Lifecycle.render_float_overlays(with_popup)
      assert overlays == []
    end
  end
end
