defmodule Minga.Agent.View.StateTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Windows

  describe "new/0" do
    test "starts inactive" do
      av = ViewState.new()
      refute av.active
    end

    test "starts with focus on :chat" do
      av = ViewState.new()
      assert av.focus == :chat
    end

    test "starts with preview scroll at 0" do
      av = ViewState.new()
      assert av.preview.scroll_offset == 0
    end

    test "starts with no saved windows" do
      av = ViewState.new()
      assert av.saved_windows == nil
    end

    test "starts with no pending prefix" do
      av = ViewState.new()
      assert av.pending_prefix == nil
    end

    test "starts with no saved file tree" do
      av = ViewState.new()
      assert av.saved_file_tree == nil
    end

    test "starts with chat_width_pct at 65" do
      av = ViewState.new()
      assert av.chat_width_pct == 65
    end
  end

  describe "activate/3" do
    test "sets active to true" do
      av = ViewState.new() |> ViewState.activate(%Windows{}, %FileTreeState{})
      assert av.active
    end

    test "saves the windows layout" do
      windows = %Windows{tree: nil, map: %{}, active: 1, next_id: 3}
      av = ViewState.new() |> ViewState.activate(windows, %FileTreeState{})
      assert av.saved_windows == windows
    end

    test "saves the file tree state" do
      ft = %FileTreeState{focused: true}
      av = ViewState.new() |> ViewState.activate(%Windows{}, ft)
      assert av.saved_file_tree == ft
    end

    test "resets focus to :chat" do
      av = %{ViewState.new() | focus: :file_viewer}
      av = ViewState.activate(av, %Windows{}, %FileTreeState{})
      assert av.focus == :chat
    end

    test "clears pending prefix" do
      av = %{ViewState.new() | pending_prefix: :z}
      av = ViewState.activate(av, %Windows{}, %FileTreeState{})
      assert av.pending_prefix == nil
    end
  end

  describe "deactivate/1" do
    test "sets active to false and returns saved windows and file tree" do
      windows = %Windows{tree: nil, map: %{}, active: 1, next_id: 2}
      ft = %FileTreeState{focused: true}

      av =
        ViewState.new()
        |> ViewState.activate(windows, ft)

      {new_av, restored_win, restored_ft} = ViewState.deactivate(av)
      refute new_av.active
      assert restored_win == windows
      assert restored_ft == ft
    end

    test "clears saved_windows and saved_file_tree after deactivation" do
      av =
        ViewState.new()
        |> ViewState.activate(%Windows{}, %FileTreeState{})

      {new_av, _, _} = ViewState.deactivate(av)
      assert new_av.saved_windows == nil
      assert new_av.saved_file_tree == nil
    end

    test "returns nil when no saved state exists" do
      {_av, restored_win, restored_ft} = ViewState.deactivate(ViewState.new())
      assert restored_win == nil
      assert restored_ft == nil
    end

    test "resets focus to :chat" do
      av = %{ViewState.new() | active: true, focus: :file_viewer}
      {new_av, _, _} = ViewState.deactivate(av)
      assert new_av.focus == :chat
    end

    test "clears pending prefix" do
      av = %{ViewState.new() | active: true, pending_prefix: :bracket_next}
      {new_av, _, _} = ViewState.deactivate(av)
      assert new_av.pending_prefix == nil
    end
  end

  describe "set_focus/2" do
    test "switches focus to :file_viewer" do
      av = ViewState.new() |> ViewState.set_focus(:file_viewer)
      assert av.focus == :file_viewer
    end

    test "switches focus to :chat" do
      av =
        %{ViewState.new() | focus: :file_viewer}
        |> ViewState.set_focus(:chat)

      assert av.focus == :chat
    end
  end

  describe "prefix state machine" do
    test "set_prefix/2 sets the pending prefix" do
      av = ViewState.new() |> ViewState.set_prefix(:g)
      assert av.pending_prefix == :g
    end

    test "set_prefix/2 accepts all valid prefixes" do
      for prefix <- [:g, :z, :bracket_next, :bracket_prev, nil] do
        av = ViewState.new() |> ViewState.set_prefix(prefix)
        assert av.pending_prefix == prefix
      end
    end

    test "clear_prefix/1 resets to nil" do
      av = %{ViewState.new() | pending_prefix: :z} |> ViewState.clear_prefix()
      assert av.pending_prefix == nil
    end

    test "backward compat: set_pending_g(true) sets prefix to :g" do
      av = ViewState.new() |> ViewState.set_pending_g(true)
      assert av.pending_prefix == :g
    end

    test "backward compat: set_pending_g(false) clears prefix" do
      av = %{ViewState.new() | pending_prefix: :g} |> ViewState.set_pending_g(false)
      assert av.pending_prefix == nil
    end

    test "backward compat: pending_g/1 returns true when prefix is :g" do
      av = ViewState.new() |> ViewState.set_prefix(:g)
      assert ViewState.pending_g(av) == true
    end

    test "backward compat: pending_g/1 returns false for other prefixes" do
      av = ViewState.new() |> ViewState.set_prefix(:z)
      assert ViewState.pending_g(av) == false
    end
  end

  describe "panel resize" do
    test "grow_chat increases chat_width_pct by 5" do
      av = ViewState.new() |> ViewState.grow_chat()
      assert av.chat_width_pct == 70
    end

    test "grow_chat clamps at 80" do
      av = %{ViewState.new() | chat_width_pct: 78} |> ViewState.grow_chat()
      assert av.chat_width_pct == 80
    end

    test "shrink_chat decreases chat_width_pct by 5" do
      av = ViewState.new() |> ViewState.shrink_chat()
      assert av.chat_width_pct == 60
    end

    test "shrink_chat clamps at 30" do
      av = %{ViewState.new() | chat_width_pct: 32} |> ViewState.shrink_chat()
      assert av.chat_width_pct == 30
    end

    test "reset_split returns to 65" do
      av = %{ViewState.new() | chat_width_pct: 45} |> ViewState.reset_split()
      assert av.chat_width_pct == 65
    end
  end

  describe "file viewer scrolling" do
    test "scroll_viewer_down increases offset" do
      av = ViewState.new() |> ViewState.scroll_viewer_down(10)
      assert av.preview.scroll_offset == 10
    end

    test "scroll_viewer_up decreases offset" do
      av =
        ViewState.new()
        |> ViewState.scroll_viewer_down(10)
        |> ViewState.scroll_viewer_up(3)

      assert av.preview.scroll_offset == 7
    end

    test "scroll_viewer_up clamps at 0" do
      av = ViewState.new() |> ViewState.scroll_viewer_up(10)
      assert av.preview.scroll_offset == 0
    end

    test "scroll_viewer_to_top resets to 0" do
      av =
        ViewState.new()
        |> ViewState.scroll_viewer_down(50)
        |> ViewState.scroll_viewer_to_top()

      assert av.preview.scroll_offset == 0
    end

    test "scroll_viewer_to_bottom sets a large offset" do
      av = ViewState.new() |> ViewState.scroll_viewer_to_bottom()
      assert av.preview.scroll_offset > 0
    end
  end

  describe "help overlay" do
    test "starts with help hidden" do
      av = ViewState.new()
      refute av.help_visible
    end

    test "toggle_help shows and hides" do
      av = ViewState.new() |> ViewState.toggle_help()
      assert av.help_visible

      av = ViewState.toggle_help(av)
      refute av.help_visible
    end

    test "dismiss_help always hides" do
      av = ViewState.new() |> ViewState.toggle_help()
      assert av.help_visible

      av = ViewState.dismiss_help(av)
      refute av.help_visible
    end

    test "dismiss_help is a no-op when already hidden" do
      av = ViewState.new() |> ViewState.dismiss_help()
      refute av.help_visible
    end
  end
end
