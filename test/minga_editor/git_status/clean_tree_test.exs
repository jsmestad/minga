defmodule MingaEditor.GitStatus.CleanTreeTest do
  use ExUnit.Case, async: true

  alias MingaEditor.GitStatus.CleanTree

  defp facts(ahead, behind), do: %{branch: "main", ahead: ahead, behind: behind}

  defp steps(empty), do: Enum.map(empty.actions, &{&1.id, &1.key, &1.label})

  test "an up-to-date clean tree says so and offers pull, then fetch, with the Done glyph" do
    empty = CleanTree.empty_list(facts(0, 0), 0)

    assert empty.glyph == "●"
    assert empty.title == "Nothing to commit on main."
    assert empty.why == "Up to date with its upstream."

    assert steps(empty) == [
             {"git_status_pull", "l", "Pull from remote"},
             {"git_status_fetch", "f", "Fetch from remote"}
           ]
  end

  test "the step that moves waiting commits comes first" do
    assert [{"git_status_push", "P", _} | _] = steps(CleanTree.empty_list(facts(2, 0), 0))

    assert [{"git_status_pull", "l", _}, {"git_status_push", "P", _} | _] =
             steps(CleanTree.empty_list(facts(1, 3), 0))
  end

  test "the why line counts the commits on each side" do
    assert CleanTree.empty_list(facts(1, 0), 0).why == "1 commit to push."
    assert CleanTree.empty_list(facts(0, 4), 0).why == "4 commits to pull."
    assert CleanTree.empty_list(facts(2, 1), 0).why == "2 commits to push, 1 commit to pull."
  end

  test "a detached or unnamed branch drops the branch from the title" do
    assert CleanTree.empty_list(%{facts(0, 0) | branch: ""}, 0).title == "Nothing to commit."
  end

  test "a cursor past the last step selects the first, and the command run is the step highlighted" do
    # The cursor was on a file row, or on Fetch before a push removed the Push step.
    for {cursor, ahead} <- [{7, 0}, {2, 0}] do
      empty = CleanTree.empty_list(facts(ahead, 0), cursor)
      assert empty.selected == 0
      highlighted = Enum.at(empty.actions, empty.selected).id
      assert Atom.to_string(CleanTree.command_at(facts(ahead, 0), cursor)) == highlighted
    end

    assert CleanTree.selected_index(facts(3, 0), 2) == 2

    assert CleanTree.commands(facts(3, 0)) == [
             :git_status_push,
             :git_status_pull,
             :git_status_fetch
           ]
  end
end
