defmodule Minga.Agent.View.StateTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.View.State, as: ViewState
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

    test "starts with file_viewer_scroll at 0" do
      av = ViewState.new()
      assert av.file_viewer_scroll == 0
    end

    test "starts with no saved windows" do
      av = ViewState.new()
      assert av.saved_windows == nil
    end
  end

  describe "activate/2" do
    test "sets active to true" do
      av = ViewState.new() |> ViewState.activate(%Windows{})
      assert av.active
    end

    test "saves the windows layout" do
      windows = %Windows{tree: nil, map: %{}, active: 1, next_id: 3}
      av = ViewState.new() |> ViewState.activate(windows)
      assert av.saved_windows == windows
    end

    test "resets focus to :chat" do
      av = %{ViewState.new() | focus: :file_viewer}
      av = ViewState.activate(av, %Windows{})
      assert av.focus == :chat
    end
  end

  describe "deactivate/1" do
    test "sets active to false and returns saved windows" do
      windows = %Windows{tree: nil, map: %{}, active: 1, next_id: 2}

      av =
        ViewState.new()
        |> ViewState.activate(windows)

      {new_av, restored} = ViewState.deactivate(av)
      refute new_av.active
      assert restored == windows
    end

    test "clears saved_windows after deactivation" do
      av =
        ViewState.new()
        |> ViewState.activate(%Windows{})

      {new_av, _} = ViewState.deactivate(av)
      assert new_av.saved_windows == nil
    end

    test "returns nil when no saved windows exist" do
      {_av, restored} = ViewState.deactivate(ViewState.new())
      assert restored == nil
    end

    test "resets focus to :chat" do
      av = %{ViewState.new() | active: true, focus: :file_viewer}
      {new_av, _} = ViewState.deactivate(av)
      assert new_av.focus == :chat
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

  describe "file viewer scrolling" do
    test "scroll_viewer_down increases offset" do
      av = ViewState.new() |> ViewState.scroll_viewer_down(10)
      assert av.file_viewer_scroll == 10
    end

    test "scroll_viewer_up decreases offset" do
      av =
        ViewState.new()
        |> ViewState.scroll_viewer_down(10)
        |> ViewState.scroll_viewer_up(3)

      assert av.file_viewer_scroll == 7
    end

    test "scroll_viewer_up clamps at 0" do
      av = ViewState.new() |> ViewState.scroll_viewer_up(10)
      assert av.file_viewer_scroll == 0
    end

    test "scroll_viewer_to_top resets to 0" do
      av =
        ViewState.new()
        |> ViewState.scroll_viewer_down(50)
        |> ViewState.scroll_viewer_to_top()

      assert av.file_viewer_scroll == 0
    end

    test "scroll_viewer_to_bottom sets a large offset" do
      av = ViewState.new() |> ViewState.scroll_viewer_to_bottom()
      assert av.file_viewer_scroll > 0
    end
  end
end
