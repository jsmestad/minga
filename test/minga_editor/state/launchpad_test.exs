defmodule MingaEditor.State.LaunchpadTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Launchpad

  defp launchpad(opts) do
    defaults = [session_file_count: 0, crashed?: false, recents: []]
    Launchpad.new(Keyword.merge(defaults, opts))
  end

  describe "item_ids/1" do
    test "orders resume, recents, then actions" do
      lp = launchpad(session_file_count: 3, recents: ["a.ex", "b.ex"])

      assert Launchpad.item_ids(lp) == [
               "resume",
               "recent-1",
               "recent-2",
               "action-find-file",
               "action-file-tree",
               "action-palette",
               "action-tutor"
             ]
    end

    test "first run promotes the Get started hero to the front" do
      lp = launchpad([])

      assert Launchpad.item_ids(lp) == [
               "action-tutor",
               "action-find-file",
               "action-file-tree",
               "action-palette"
             ]
    end
  end

  describe "initial focus" do
    test "prefers the resume item when a session exists" do
      assert launchpad(session_file_count: 2, recents: ["a.ex"]).focused_id == "resume"
    end

    test "falls back to the first recent, then the first-run hero" do
      assert launchpad(recents: ["a.ex"]).focused_id == "recent-1"
      assert launchpad([]).focused_id == "action-tutor"
    end
  end

  describe "move_focus/2" do
    test "next and prev clamp at the edges" do
      lp = launchpad(recents: ["a.ex"])
      assert lp.focused_id == "recent-1"

      lp = Launchpad.move_focus(lp, :prev)
      assert lp.focused_id == "recent-1"

      lp = lp |> Launchpad.move_focus(:next) |> Launchpad.move_focus(:next)
      assert lp.focused_id == "action-file-tree"

      lp = Enum.reduce(1..10, lp, fn _, acc -> Launchpad.move_focus(acc, :next) end)
      assert lp.focused_id == "action-tutor"
    end

    test "first and last jump to the edges" do
      lp = launchpad(session_file_count: 1, recents: ["a.ex"])

      assert Launchpad.move_focus(lp, :last).focused_id == "action-tutor"

      back_to_first = lp |> Launchpad.move_focus(:last) |> Launchpad.move_focus(:first)
      assert back_to_first.focused_id == "resume"
    end
  end

  describe "gg chord" do
    test "first g arms, second g jumps to first" do
      lp = launchpad(session_file_count: 1) |> Launchpad.move_focus(:last)

      armed = Launchpad.press_g(lp)
      assert armed.pending_g?
      assert armed.focused_id == "action-tutor"

      done = Launchpad.press_g(armed)
      refute done.pending_g?
      assert done.focused_id == "resume"
    end

    test "clear_pending_g disarms" do
      lp = launchpad([]) |> Launchpad.press_g() |> Launchpad.clear_pending_g()
      refute lp.pending_g?
    end

    test "focus/2 and move_focus/2 respect first-run ordering" do
      lp = launchpad([])

      assert Launchpad.move_focus(lp, :next).focused_id == "action-find-file"
      assert Launchpad.move_focus(lp, :last).focused_id == "action-palette"

      assert lp
             |> Launchpad.move_focus(:last)
             |> Launchpad.move_focus(:first)
             |> Map.fetch!(:focused_id) == "action-tutor"
    end
  end

  describe "recent_path/2" do
    test "resolves 1-based recent ids and rejects unknown ids" do
      lp = launchpad(recents: ["lib/a.ex", "lib/b.ex"])

      assert Launchpad.recent_path(lp, "recent-1") == "lib/a.ex"
      assert Launchpad.recent_path(lp, "recent-2") == "lib/b.ex"
      assert Launchpad.recent_path(lp, "recent-3") == nil
      assert Launchpad.recent_path(lp, "resume") == nil
    end
  end

  test "focus/2 only accepts existing item ids" do
    lp = launchpad(recents: ["a.ex"])

    assert Launchpad.focus(lp, "action-palette").focused_id == "action-palette"
    assert Launchpad.focus(lp, "bogus").focused_id == "recent-1"
  end

  test "recents cap at five" do
    lp = launchpad(recents: Enum.map(1..9, &"file#{&1}.ex"))
    assert [_, _, _, _, _] = lp.recents
  end
end
