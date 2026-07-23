defmodule MingaEditor.Agent.UIState.ViewFunctionsTest do
  use ExUnit.Case, async: true

  alias Minga.Git
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Windows

  describe "new/0" do
    test "starts inactive" do
      ui = UIState.new()
      refute View.active?(ui.view)
    end

    test "starts with focus on :chat" do
      ui = UIState.new()
      assert View.focus(ui.view) == :chat
    end

    test "starts with preview scroll at 0" do
      ui = UIState.new()
      assert ui.view.preview.scroll.offset == 0
    end

    test "starts with no saved windows" do
      ui = UIState.new()
      assert ui.view.presentation.saved_windows == nil
    end

    test "starts with no pending prefix" do
      ui = UIState.new()
      assert View.pending_prefix(ui.view) == nil
    end

    test "starts with no saved file tree" do
      ui = UIState.new()
      assert ui.view.presentation.saved_file_tree == nil
    end

    test "starts with chat_width_pct at 65" do
      ui = UIState.new()
      assert ui.view.chat_width_pct == 65
    end
  end

  describe "activate/3" do
    test "sets active to true" do
      ui = UIState.new() |> UIState.activate(%Windows{}, %FileTreeState{})
      assert View.active?(ui.view)
    end

    test "saves the windows layout" do
      windows = %Windows{tree: nil, map: %{}, active: 1, next_id: 3}
      ui = UIState.new() |> UIState.activate(windows, %FileTreeState{})
      assert ui.view.presentation.saved_windows == windows
    end

    test "saves the file tree state" do
      ft = %FileTreeState{visibility: :focused}
      ui = UIState.new() |> UIState.activate(%Windows{}, ft)
      assert ui.view.presentation.saved_file_tree == ft
    end

    test "resets focus to :chat" do
      ui = UIState.new() |> UIState.set_focus(:file_viewer)
      ui = UIState.activate(ui, %Windows{}, %FileTreeState{})
      assert View.focus(ui.view) == :chat
    end

    test "clears pending prefix" do
      ui = UIState.new() |> UIState.set_prefix(:z)
      ui = UIState.activate(ui, %Windows{}, %FileTreeState{})
      assert View.pending_prefix(ui.view) == nil
    end
  end

  describe "deactivate/1" do
    test "sets active to false and returns saved windows and file tree" do
      windows = %Windows{tree: nil, map: %{}, active: 1, next_id: 2}
      ft = %FileTreeState{visibility: :focused}

      ui =
        UIState.new()
        |> UIState.activate(windows, ft)

      {new_ui, restored_win, restored_ft} = UIState.deactivate(ui)
      refute View.active?(new_ui.view)
      assert restored_win == windows
      assert restored_ft == ft
    end

    test "clears saved_windows and saved_file_tree after deactivation" do
      ui =
        UIState.new()
        |> UIState.activate(%Windows{}, %FileTreeState{})

      {new_ui, _, _} = UIState.deactivate(ui)
      assert new_ui.view.presentation.saved_windows == nil
      assert new_ui.view.presentation.saved_file_tree == nil
    end

    test "returns nil when no saved state exists" do
      {_ui, restored_win, restored_ft} = UIState.deactivate(UIState.new())
      assert restored_win == nil
      assert restored_ft == nil
    end

    test "resets focus to :chat" do
      ui = UIState.new() |> UIState.activate(nil, nil) |> UIState.set_focus(:file_viewer)
      {new_ui, _, _} = UIState.deactivate(ui)
      assert View.focus(new_ui.view) == :chat
    end

    test "clears pending prefix" do
      ui = UIState.new() |> UIState.activate(nil, nil) |> UIState.set_prefix(:bracket_next)
      {new_ui, _, _} = UIState.deactivate(ui)
      assert View.pending_prefix(new_ui.view) == nil
    end
  end

  describe "set_focus/2" do
    test "switches focus to :file_viewer" do
      ui = UIState.new() |> UIState.set_focus(:file_viewer)
      assert View.focus(ui.view) == :file_viewer
    end

    test "switches focus to :chat" do
      ui =
        UIState.new()
        |> UIState.set_focus(:file_viewer)
        |> UIState.set_focus(:chat)

      assert View.focus(ui.view) == :chat
    end
  end

  describe "prefix state machine" do
    test "set_prefix/2 sets the pending prefix" do
      ui = UIState.new() |> UIState.set_prefix(:g)
      assert View.pending_prefix(ui.view) == :g
    end

    test "set_prefix/2 accepts all valid prefixes" do
      for prefix <- [:g, :z, :bracket_next, :bracket_prev, nil] do
        ui = UIState.new() |> UIState.set_prefix(prefix)
        assert View.pending_prefix(ui.view) == prefix
      end
    end

    test "clear_prefix/1 resets to nil" do
      ui = UIState.new() |> UIState.set_prefix(:z) |> UIState.clear_prefix()
      assert View.pending_prefix(ui.view) == nil
    end
  end

  describe "panel resize" do
    test "grow_chat increases chat_width_pct by 5" do
      ui = UIState.new() |> UIState.grow_chat()
      assert ui.view.chat_width_pct == 70
    end

    test "grow_chat clamps at 80" do
      ui = put_in(UIState.new().view.chat_width_pct, 78) |> UIState.grow_chat()
      assert ui.view.chat_width_pct == 80
    end

    test "shrink_chat decreases chat_width_pct by 5" do
      ui = UIState.new() |> UIState.shrink_chat()
      assert ui.view.chat_width_pct == 60
    end

    test "shrink_chat clamps at 30" do
      ui = put_in(UIState.new().view.chat_width_pct, 32) |> UIState.shrink_chat()
      assert ui.view.chat_width_pct == 30
    end

    test "reset_split returns to 65" do
      ui = put_in(UIState.new().view.chat_width_pct, 45) |> UIState.reset_split()
      assert ui.view.chat_width_pct == 65
    end
  end

  describe "file viewer scrolling" do
    test "scroll_viewer_down increases offset" do
      ui = UIState.new() |> UIState.scroll_viewer_down(10)
      assert ui.view.preview.scroll.offset == 10
    end

    test "scroll_viewer_up decreases offset" do
      ui =
        UIState.new()
        |> UIState.scroll_viewer_down(10)
        |> UIState.scroll_viewer_up(3)

      assert ui.view.preview.scroll.offset == 7
    end

    test "scroll_viewer_up clamps at 0" do
      ui = UIState.new() |> UIState.scroll_viewer_up(10)
      assert ui.view.preview.scroll.offset == 0
    end

    test "scroll_viewer_to_top resets to 0" do
      ui =
        UIState.new()
        |> UIState.scroll_viewer_down(50)
        |> UIState.scroll_viewer_to_top()

      assert ui.view.preview.scroll.offset == 0
    end

    test "scroll_viewer_to_bottom engages auto_follow" do
      ui =
        UIState.new() |> UIState.scroll_viewer_down(5) |> UIState.scroll_viewer_to_bottom()

      assert ui.view.preview.scroll.pinned
    end
  end

  describe "help overlay" do
    test "starts with help hidden" do
      ui = UIState.new()
      refute ui.view.help_visible
    end

    test "toggle_help shows and hides" do
      ui = UIState.new() |> UIState.toggle_help()
      assert ui.view.help_visible

      ui = UIState.toggle_help(ui)
      refute ui.view.help_visible
    end

    test "dismiss_help always hides" do
      ui = UIState.new() |> UIState.toggle_help()
      assert ui.view.help_visible

      ui = UIState.dismiss_help(ui)
      refute ui.view.help_visible
    end

    test "dismiss_help is a no-op when already hidden" do
      ui = UIState.new() |> UIState.dismiss_help()
      refute ui.view.help_visible
    end
  end

  describe "search" do
    test "starts with no search" do
      ui = UIState.new()
      refute UIState.searching?(ui)
      refute UIState.search_input_active?(ui)
    end

    test "start_search activates search with saved scroll" do
      ui = UIState.new() |> UIState.start_search(42)
      assert UIState.searching?(ui)
      assert UIState.search_input_active?(ui)
      assert UIState.search_saved_scroll(ui) == 42
      assert UIState.search_query(ui) == ""
    end

    test "update_search_query modifies the query" do
      ui = UIState.new() |> UIState.start_search(0) |> UIState.update_search_query("hello")
      assert UIState.search_query(ui) == "hello"
    end

    test "set_search_matches stores matches and resets current" do
      ui = UIState.new() |> UIState.start_search(0)
      matches = [{0, 5, 10}, {1, 0, 5}]
      ui = UIState.set_search_matches(ui, matches)
      assert ui.view.search.matches == matches
      assert ui.view.search.current == 0
    end

    test "next_search_match cycles forward" do
      ui =
        UIState.new()
        |> UIState.start_search(0)
        |> UIState.set_search_matches([{0, 0, 5}, {1, 0, 5}, {2, 0, 5}])

      ui = UIState.next_search_match(ui)
      assert ui.view.search.current == 1
      ui = UIState.next_search_match(ui)
      assert ui.view.search.current == 2
      ui = UIState.next_search_match(ui)
      assert ui.view.search.current == 0
    end

    test "prev_search_match cycles backward" do
      ui =
        UIState.new()
        |> UIState.start_search(0)
        |> UIState.set_search_matches([{0, 0, 5}, {1, 0, 5}, {2, 0, 5}])

      ui = UIState.prev_search_match(ui)
      assert ui.view.search.current == 2
      ui = UIState.prev_search_match(ui)
      assert ui.view.search.current == 1
    end

    test "cancel_search clears the search state" do
      ui = UIState.new() |> UIState.start_search(10) |> UIState.cancel_search()
      refute UIState.searching?(ui)
      assert ui.view.search == nil
    end

    test "confirm_search clears search when no matches" do
      ui = UIState.new() |> UIState.start_search(0) |> UIState.confirm_search()
      refute UIState.searching?(ui)
    end

    test "confirm_search keeps matches and disables input" do
      ui =
        UIState.new()
        |> UIState.start_search(0)
        |> UIState.set_search_matches([{0, 0, 5}])
        |> UIState.confirm_search()

      assert UIState.searching?(ui)
      refute UIState.search_input_active?(ui)
    end

    test "next/prev no-op when no search" do
      ui = UIState.new()
      assert ui == UIState.next_search_match(ui)
      assert ui == UIState.prev_search_match(ui)
    end

    test "next/prev no-op when no matches" do
      ui = UIState.new() |> UIState.start_search(0)
      assert ui == UIState.next_search_match(ui)
      assert ui == UIState.prev_search_match(ui)
    end
  end

  describe "toasts" do
    test "starts with no toast" do
      ui = UIState.new()
      refute UIState.toast_visible?(ui)
    end

    test "push_toast sets current toast when empty" do
      ui = UIState.new() |> UIState.push_toast("Hello", :info)
      assert UIState.toast_visible?(ui)
      assert ui.view.toast.message == "Hello"
      assert ui.view.toast.icon == "✓"
      assert ui.view.toast.level == :info
    end

    test "push_toast queues when a toast is already showing" do
      ui =
        UIState.new()
        |> UIState.push_toast("First", :info)
        |> UIState.push_toast("Second", :warning)

      assert ui.view.toast.message == "First"
      assert :queue.len(ui.view.toast_queue) == 1
    end

    test "dismiss_toast shows next from queue" do
      ui =
        UIState.new()
        |> UIState.push_toast("First", :info)
        |> UIState.push_toast("Second", :warning)
        |> UIState.dismiss_toast()

      assert ui.view.toast.message == "Second"
      assert ui.view.toast.icon == "⚠"
    end

    test "dismiss_toast clears when queue is empty" do
      ui =
        UIState.new()
        |> UIState.push_toast("Only", :info)
        |> UIState.dismiss_toast()

      refute UIState.toast_visible?(ui)
    end

    test "clear_toasts removes everything" do
      ui =
        UIState.new()
        |> UIState.push_toast("A", :info)
        |> UIState.push_toast("B", :error)
        |> UIState.clear_toasts()

      refute UIState.toast_visible?(ui)
    end

    test "error toast has ✗ icon" do
      ui = UIState.new() |> UIState.push_toast("Fail", :error)
      assert ui.view.toast.icon == "✗"
    end

    test "warning toast has ⚠ icon" do
      ui = UIState.new() |> UIState.push_toast("Warn", :warning)
      assert ui.view.toast.icon == "⚠"
    end
  end

  describe "resolve_diff_review/2" do
    test "reject current reprojects timeline and returns write target" do
      review = DiffReview.new("lib/a.ex", "a", "x\na")

      view = %{
        View.new()
        | preview: Preview.set_diff(Preview.new(), review),
          edit_timeline: EditTimeline.reproject(EditTimeline.new(), "lib/a.ex", ["a"], ["x", "a"])
      }

      assert {:ok, view, {:write_file, "lib/a.ex", "a"}} =
               View.resolve_diff_review(view, :reject_current)

      assert EditTimeline.cumulative_hunks(view.edit_timeline, "lib/a.ex") ==
               Git.diff_lines(["a"], ["a"])

      refute Preview.diff_review(view.preview)
    end
  end

  describe "edit timeline reset" do
    test "reset_edit_timeline clears entries and hunk projections" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "old", "new")
        |> EditTimeline.set_viewing("lib/foo.ex", 0)

      ui =
        UIState.new()
        |> UIState.replace_edit_timeline(timeline)
        |> UIState.reset_edit_timeline()

      assert ui.view.edit_timeline == EditTimeline.new()
    end
  end
end
