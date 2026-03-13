defmodule Minga.Input.PopupTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Input.Popup, as: PopupHandler
  alias Minga.Mode
  alias Minga.Popup.Active, as: PopupActive
  alias Minga.Popup.Rule

  defp fake_pid do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  defp build_state_with_popup(opts \\ []) do
    quit_key = Keyword.get(opts, :quit_key, "q")
    focus_popup = Keyword.get(opts, :focus_popup, true)
    mode = Keyword.get(opts, :mode, :normal)

    main_buf = fake_pid()
    popup_buf = fake_pid()

    main_window = Window.new(1, main_buf, 24, 80)

    rule = Rule.new("*test*", quit_key: quit_key)
    active = PopupActive.new(rule, 2, WindowTree.new(1), 1)
    popup_window = %{Window.new(2, popup_buf, 24, 80) | popup_meta: active}

    %EditorState{
      port_manager: nil,
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      mode: mode,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: main_buf, list: [main_buf]},
      windows: %Windows{
        tree: {:split, :horizontal, {:leaf, 1}, {:leaf, 2}, 16},
        map: %{1 => main_window, 2 => popup_window},
        active: if(focus_popup, do: 2, else: 1),
        next_id: 3
      }
    }
  end

  defp build_state_no_popup do
    main_buf = fake_pid()
    main_window = Window.new(1, main_buf, 24, 80)

    %EditorState{
      port_manager: nil,
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: main_buf, list: [main_buf]},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => main_window},
        active: 1,
        next_id: 2
      }
    }
  end

  describe "handle_key/3" do
    test "passes through when no popup is active" do
      state = build_state_no_popup()

      assert {:passthrough, ^state} = PopupHandler.handle_key(state, ?q, 0)
    end

    test "passes through when popup is active but focus is on a non-popup window" do
      state = build_state_with_popup(focus_popup: false)

      assert {:passthrough, ^state} = PopupHandler.handle_key(state, ?q, 0)
    end

    test "closes the popup when quit key is pressed in normal mode" do
      state = build_state_with_popup()

      assert {:handled, new_state} = PopupHandler.handle_key(state, ?q, 0)

      # Popup window should be removed
      assert map_size(new_state.windows.map) == 1
      assert Map.has_key?(new_state.windows.map, 1)
      refute Map.has_key?(new_state.windows.map, 2)

      # Focus should be restored to window 1
      assert new_state.windows.active == 1

      # Tree should be restored
      assert {:leaf, 1} = new_state.windows.tree
    end

    test "passes through quit key in insert mode" do
      state = build_state_with_popup(mode: :insert)

      assert {:passthrough, ^state} = PopupHandler.handle_key(state, ?q, 0)
    end

    test "passes through non-quit keys in normal mode" do
      state = build_state_with_popup()

      # j key should pass through for normal navigation
      assert {:passthrough, ^state} = PopupHandler.handle_key(state, ?j, 0)
    end

    test "respects custom quit key" do
      state = build_state_with_popup(quit_key: "x")

      # Default q should pass through
      assert {:passthrough, ^state} = PopupHandler.handle_key(state, ?q, 0)

      # Custom x should close
      assert {:handled, new_state} = PopupHandler.handle_key(state, ?x, 0)
      assert map_size(new_state.windows.map) == 1
    end
  end
end
