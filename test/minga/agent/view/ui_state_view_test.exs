defmodule Minga.Agent.UIState.ViewFunctionsTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.UIState
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Windows

  describe "new/0" do
    test "starts inactive" do
      av = UIState.new()
      refute av.active
    end

    test "starts with focus on :chat" do
      av = UIState.new()
      assert av.focus == :chat
    end

    test "starts with preview scroll at 0" do
      av = UIState.new()
      assert av.preview.scroll.offset == 0
    end

    test "starts with no saved windows" do
      av = UIState.new()
      assert av.saved_windows == nil
    end

    test "starts with no pending prefix" do
      av = UIState.new()
      assert av.pending_prefix == nil
    end

    test "starts with no saved file tree" do
      av = UIState.new()
      assert av.saved_file_tree == nil
    end

    test "starts with chat_width_pct at 65" do
      av = UIState.new()
      assert av.chat_width_pct == 65
    end
  end

  describe "activate/3" do
    test "sets active to true" do
      av = UIState.new() |> UIState.activate(%Windows{}, %FileTreeState{})
      assert av.active
    end

    test "saves the windows layout" do
      windows = %Windows{tree: nil, map: %{}, active: 1, next_id: 3}
      av = UIState.new() |> UIState.activate(windows, %FileTreeState{})
      assert av.saved_windows == windows
    end

    test "saves the file tree state" do
      ft = %FileTreeState{focused: true}
      av = UIState.new() |> UIState.activate(%Windows{}, ft)
      assert av.saved_file_tree == ft
    end

    test "resets focus to :chat" do
      av = %{UIState.new() | focus: :file_viewer}
      av = UIState.activate(av, %Windows{}, %FileTreeState{})
      assert av.focus == :chat
    end

    test "clears pending prefix" do
      av = %{UIState.new() | pending_prefix: :z}
      av = UIState.activate(av, %Windows{}, %FileTreeState{})
      assert av.pending_prefix == nil
    end
  end

  describe "deactivate/1" do
    test "sets active to false and returns saved windows and file tree" do
      windows = %Windows{tree: nil, map: %{}, active: 1, next_id: 2}
      ft = %FileTreeState{focused: true}

      av =
        UIState.new()
        |> UIState.activate(windows, ft)

      {new_av, restored_win, restored_ft} = UIState.deactivate(av)
      refute new_av.active
      assert restored_win == windows
      assert restored_ft == ft
    end

    test "clears saved_windows and saved_file_tree after deactivation" do
      av =
        UIState.new()
        |> UIState.activate(%Windows{}, %FileTreeState{})

      {new_av, _, _} = UIState.deactivate(av)
      assert new_av.saved_windows == nil
      assert new_av.saved_file_tree == nil
    end

    test "returns nil when no saved state exists" do
      {_av, restored_win, restored_ft} = UIState.deactivate(UIState.new())
      assert restored_win == nil
      assert restored_ft == nil
    end

    test "resets focus to :chat" do
      av = %{UIState.new() | active: true, focus: :file_viewer}
      {new_av, _, _} = UIState.deactivate(av)
      assert new_av.focus == :chat
    end

    test "clears pending prefix" do
      av = %{UIState.new() | active: true, pending_prefix: :bracket_next}
      {new_av, _, _} = UIState.deactivate(av)
      assert new_av.pending_prefix == nil
    end
  end

  describe "set_focus/2" do
    test "switches focus to :file_viewer" do
      av = UIState.new() |> UIState.set_focus(:file_viewer)
      assert av.focus == :file_viewer
    end

    test "switches focus to :chat" do
      av =
        %{UIState.new() | focus: :file_viewer}
        |> UIState.set_focus(:chat)

      assert av.focus == :chat
    end
  end

  describe "prefix state machine" do
    test "set_prefix/2 sets the pending prefix" do
      av = UIState.new() |> UIState.set_prefix(:g)
      assert av.pending_prefix == :g
    end

    test "set_prefix/2 accepts all valid prefixes" do
      for prefix <- [:g, :z, :bracket_next, :bracket_prev, nil] do
        av = UIState.new() |> UIState.set_prefix(prefix)
        assert av.pending_prefix == prefix
      end
    end

    test "clear_prefix/1 resets to nil" do
      av = %{UIState.new() | pending_prefix: :z} |> UIState.clear_prefix()
      assert av.pending_prefix == nil
    end

    test "backward compat: set_pending_g(true) sets prefix to :g" do
      av = UIState.new() |> UIState.set_pending_g(true)
      assert av.pending_prefix == :g
    end

    test "backward compat: set_pending_g(false) clears prefix" do
      av = %{UIState.new() | pending_prefix: :g} |> UIState.set_pending_g(false)
      assert av.pending_prefix == nil
    end

    test "backward compat: pending_g/1 returns true when prefix is :g" do
      av = UIState.new() |> UIState.set_prefix(:g)
      assert UIState.pending_g(av) == true
    end

    test "backward compat: pending_g/1 returns false for other prefixes" do
      av = UIState.new() |> UIState.set_prefix(:z)
      assert UIState.pending_g(av) == false
    end
  end

  describe "panel resize" do
    test "grow_chat increases chat_width_pct by 5" do
      av = UIState.new() |> UIState.grow_chat()
      assert av.chat_width_pct == 70
    end

    test "grow_chat clamps at 80" do
      av = %{UIState.new() | chat_width_pct: 78} |> UIState.grow_chat()
      assert av.chat_width_pct == 80
    end

    test "shrink_chat decreases chat_width_pct by 5" do
      av = UIState.new() |> UIState.shrink_chat()
      assert av.chat_width_pct == 60
    end

    test "shrink_chat clamps at 30" do
      av = %{UIState.new() | chat_width_pct: 32} |> UIState.shrink_chat()
      assert av.chat_width_pct == 30
    end

    test "reset_split returns to 65" do
      av = %{UIState.new() | chat_width_pct: 45} |> UIState.reset_split()
      assert av.chat_width_pct == 65
    end
  end

  describe "file viewer scrolling" do
    test "scroll_viewer_down increases offset" do
      av = UIState.new() |> UIState.scroll_viewer_down(10)
      assert av.preview.scroll.offset == 10
    end

    test "scroll_viewer_up decreases offset" do
      av =
        UIState.new()
        |> UIState.scroll_viewer_down(10)
        |> UIState.scroll_viewer_up(3)

      assert av.preview.scroll.offset == 7
    end

    test "scroll_viewer_up clamps at 0" do
      av = UIState.new() |> UIState.scroll_viewer_up(10)
      assert av.preview.scroll.offset == 0
    end

    test "scroll_viewer_to_top resets to 0" do
      av =
        UIState.new()
        |> UIState.scroll_viewer_down(50)
        |> UIState.scroll_viewer_to_top()

      assert av.preview.scroll.offset == 0
    end

    test "scroll_viewer_to_bottom engages auto_follow" do
      av =
        UIState.new() |> UIState.scroll_viewer_down(5) |> UIState.scroll_viewer_to_bottom()

      assert av.preview.scroll.pinned
    end
  end

  describe "help overlay" do
    test "starts with help hidden" do
      av = UIState.new()
      refute av.help_visible
    end

    test "toggle_help shows and hides" do
      av = UIState.new() |> UIState.toggle_help()
      assert av.help_visible

      av = UIState.toggle_help(av)
      refute av.help_visible
    end

    test "dismiss_help always hides" do
      av = UIState.new() |> UIState.toggle_help()
      assert av.help_visible

      av = UIState.dismiss_help(av)
      refute av.help_visible
    end

    test "dismiss_help is a no-op when already hidden" do
      av = UIState.new() |> UIState.dismiss_help()
      refute av.help_visible
    end
  end

  describe "search" do
    test "starts with no search" do
      av = UIState.new()
      refute UIState.searching?(av)
      refute UIState.search_input_active?(av)
    end

    test "start_search activates search with saved scroll" do
      av = UIState.new() |> UIState.start_search(42)
      assert UIState.searching?(av)
      assert UIState.search_input_active?(av)
      assert UIState.search_saved_scroll(av) == 42
      assert UIState.search_query(av) == ""
    end

    test "update_search_query modifies the query" do
      av = UIState.new() |> UIState.start_search(0) |> UIState.update_search_query("hello")
      assert UIState.search_query(av) == "hello"
    end

    test "set_search_matches stores matches and resets current" do
      av = UIState.new() |> UIState.start_search(0)
      matches = [{0, 5, 10}, {1, 0, 5}]
      av = UIState.set_search_matches(av, matches)
      assert av.search.matches == matches
      assert av.search.current == 0
    end

    test "next_search_match cycles forward" do
      av =
        UIState.new()
        |> UIState.start_search(0)
        |> UIState.set_search_matches([{0, 0, 5}, {1, 0, 5}, {2, 0, 5}])

      av = UIState.next_search_match(av)
      assert av.search.current == 1
      av = UIState.next_search_match(av)
      assert av.search.current == 2
      av = UIState.next_search_match(av)
      assert av.search.current == 0
    end

    test "prev_search_match cycles backward" do
      av =
        UIState.new()
        |> UIState.start_search(0)
        |> UIState.set_search_matches([{0, 0, 5}, {1, 0, 5}, {2, 0, 5}])

      av = UIState.prev_search_match(av)
      assert av.search.current == 2
      av = UIState.prev_search_match(av)
      assert av.search.current == 1
    end

    test "cancel_search clears the search state" do
      av = UIState.new() |> UIState.start_search(10) |> UIState.cancel_search()
      refute UIState.searching?(av)
      assert av.search == nil
    end

    test "confirm_search clears search when no matches" do
      av = UIState.new() |> UIState.start_search(0) |> UIState.confirm_search()
      refute UIState.searching?(av)
    end

    test "confirm_search keeps matches and disables input" do
      av =
        UIState.new()
        |> UIState.start_search(0)
        |> UIState.set_search_matches([{0, 0, 5}])
        |> UIState.confirm_search()

      assert UIState.searching?(av)
      refute UIState.search_input_active?(av)
    end

    test "next/prev no-op when no search" do
      av = UIState.new()
      assert av == UIState.next_search_match(av)
      assert av == UIState.prev_search_match(av)
    end

    test "next/prev no-op when no matches" do
      av = UIState.new() |> UIState.start_search(0)
      assert av == UIState.next_search_match(av)
      assert av == UIState.prev_search_match(av)
    end
  end

  describe "toasts" do
    test "starts with no toast" do
      av = UIState.new()
      refute UIState.toast_visible?(av)
    end

    test "push_toast sets current toast when empty" do
      av = UIState.new() |> UIState.push_toast("Hello", :info)
      assert UIState.toast_visible?(av)
      assert av.toast.message == "Hello"
      assert av.toast.icon == "✓"
      assert av.toast.level == :info
    end

    test "push_toast queues when a toast is already showing" do
      av =
        UIState.new()
        |> UIState.push_toast("First", :info)
        |> UIState.push_toast("Second", :warning)

      assert av.toast.message == "First"
      assert :queue.len(av.toast_queue) == 1
    end

    test "dismiss_toast shows next from queue" do
      av =
        UIState.new()
        |> UIState.push_toast("First", :info)
        |> UIState.push_toast("Second", :warning)
        |> UIState.dismiss_toast()

      assert av.toast.message == "Second"
      assert av.toast.icon == "⚠"
    end

    test "dismiss_toast clears when queue is empty" do
      av =
        UIState.new()
        |> UIState.push_toast("Only", :info)
        |> UIState.dismiss_toast()

      refute UIState.toast_visible?(av)
    end

    test "clear_toasts removes everything" do
      av =
        UIState.new()
        |> UIState.push_toast("A", :info)
        |> UIState.push_toast("B", :error)
        |> UIState.clear_toasts()

      refute UIState.toast_visible?(av)
    end

    test "error toast has ✗ icon" do
      av = UIState.new() |> UIState.push_toast("Fail", :error)
      assert av.toast.icon == "✗"
    end

    test "warning toast has ⚠ icon" do
      av = UIState.new() |> UIState.push_toast("Warn", :warning)
      assert av.toast.icon == "⚠"
    end
  end

  describe "diff baselines" do
    test "record_baseline stores content on first call" do
      av = UIState.new()
      av = UIState.record_baseline(av, "lib/foo.ex", "original content")
      assert UIState.get_baseline(av, "lib/foo.ex") == "original content"
    end

    test "record_baseline is a no-op on subsequent calls for same path" do
      av = UIState.new()
      av = UIState.record_baseline(av, "lib/foo.ex", "original")
      av = UIState.record_baseline(av, "lib/foo.ex", "modified")
      assert UIState.get_baseline(av, "lib/foo.ex") == "original"
    end

    test "record_baseline tracks multiple paths independently" do
      av = UIState.new()
      av = UIState.record_baseline(av, "lib/a.ex", "content_a")
      av = UIState.record_baseline(av, "lib/b.ex", "content_b")
      assert UIState.get_baseline(av, "lib/a.ex") == "content_a"
      assert UIState.get_baseline(av, "lib/b.ex") == "content_b"
    end

    test "clear_baselines removes all baselines" do
      av = UIState.new()
      av = UIState.record_baseline(av, "lib/foo.ex", "content")
      av = UIState.clear_baselines(av)
      assert UIState.get_baseline(av, "lib/foo.ex") == nil
    end

    test "get_baseline returns nil for unknown path" do
      av = UIState.new()
      assert UIState.get_baseline(av, "lib/unknown.ex") == nil
    end
  end
end
