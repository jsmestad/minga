defmodule Minga.Mode.SubstituteConfirmTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Search.Match
  alias Minga.Mode
  alias Minga.Mode.SubstituteConfirmState

  setup do
    matches = [Match.new(0, 0, 3), Match.new(0, 8, 3), Match.new(1, 5, 3)]
    [first, second, last] = matches
    state = SubstituteConfirmState.new(matches, "foo", "bar", "foo and foo\nblah foo")
    %{state: state, first: first, second: second, last: last}
  end

  test "y accepts the current match and advances once without resetting progress", %{
    state: state,
    first: first,
    second: second
  } do
    assert {:substitute_confirm, [:substitute_confirm_advance], next} = press(state, ?y)
    assert SubstituteConfirmState.accepted_matches(next) == [first]
    assert SubstituteConfirmState.current_match(next) == second
    assert Mode.display(:substitute_confirm, next) == "replace with bar? [y/n/a/q] (2 of 3)"
  end

  test "n advances without accepting the current match", %{state: state, second: second} do
    assert {:substitute_confirm, [:substitute_confirm_advance], next} = press(state, ?n)
    assert SubstituteConfirmState.accepted_matches(next) == []
    assert SubstituteConfirmState.current_match(next) == second
  end

  test "y and n on the last offer apply without requesting another cursor move", %{
    state: state,
    last: last
  } do
    assert {:substitute_confirm, [:substitute_confirm_advance], second} = press(state, ?n)
    assert {:substitute_confirm, [:substitute_confirm_advance], third} = press(second, ?n)

    assert {:normal, [:apply_substitute_confirm], accepted} = press(third, ?y)
    assert SubstituteConfirmState.accepted_matches(accepted) == [last]
    assert SubstituteConfirmState.current_match(accepted) == nil

    assert {:normal, [:apply_substitute_confirm], skipped} = press(third, ?n)
    assert SubstituteConfirmState.accepted_matches(skipped) == []
    assert SubstituteConfirmState.current_match(skipped) == nil
  end

  test "a sends all remaining offers before earlier accepts in reverse offered order", %{
    state: state,
    first: first,
    second: second,
    last: last
  } do
    assert {:substitute_confirm, [:substitute_confirm_advance], next} = press(state, ?y)
    assert {:normal, [:apply_substitute_confirm], done} = press(next, ?a)
    assert SubstituteConfirmState.accepted_matches(done) == [last, second, first]
    assert SubstituteConfirmState.current_match(done) == nil
  end

  test "q and Escape apply only decisions already made", %{state: state, first: first} do
    assert {:substitute_confirm, [:substitute_confirm_advance], next} = press(state, ?y)

    for key <- [?q, 27] do
      assert {:normal, [:apply_substitute_confirm], done} = press(next, key)
      assert SubstituteConfirmState.accepted_matches(done) == [first]
    end
  end

  test "other keys, including digits, do not advance the offer", %{state: state} do
    for key <- [?x, ?1] do
      assert {:substitute_confirm, [], ^state} = press(state, key)
    end
  end

  defp press(state, key), do: Mode.process(:substitute_confirm, {key, 0}, state)
end
