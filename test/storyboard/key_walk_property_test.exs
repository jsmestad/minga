defmodule Minga.Storyboard.KeyWalkPropertyTest do
  @moduledoc """
  A random walk over the active trie's keys, asserting flow-graph invariants 2 and 6 after every step.

  Invariant 6: the editor survives the key (a dead editor fails the next key press) and the frame is defined (it builds, and a pending leader sequence always has which-key open, since the walk pauses after every prefix). Invariant 2: from that frame, three presses of `esc` or `q` reach plain editing in the starting window. The way-out check consumes the state, so it runs on a replay of the walk so far in a fresh editor; the walk is a list of choices, so a replay is exact.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Test.Storyboard.Explorer
  alias Minga.Test.Storyboard.KeyWalk
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Session

  @moduletag :storyboard
  @moduletag timeout: 300_000

  # A walk that cannot see the keymap degrades to esc alone and passes vacuously, so check the alphabet first (#4112).
  test "the walk reads the leader's children and the Vim normal keys from the keymap" do
    for {id, at_least} <- [{"edit.whichkey.leader", 10}, {Registry.home(), 20}] do
      Explorer.with_session(fn -> Registry.drive(id) end, fn session ->
        keys = session |> Session.model() |> KeyWalk.alphabet()
        assert length(keys) > at_least, "#{id}: the walk can only press #{inspect(keys)}"
      end)
    end
  end

  property "every step of a random key walk keeps a way out and lands on a defined state" do
    check all(choices <- list_of(integer(0..10_000), min_length: 1, max_length: 6), max_runs: 25) do
      walk(choices)
    end
  end

  @spec walk([non_neg_integer()]) :: :ok
  defp walk(choices) do
    Explorer.with_session(fn -> Registry.drive(Registry.home()) end, &walk(&1, choices))
  end

  @spec walk(Session.t(), [non_neg_integer()]) :: :ok
  defp walk(start, choices) do
    {_session, _keys} =
      choices
      |> Enum.with_index(1)
      |> Enum.reduce({start, []}, &walk_step(&1, &2, choices))

    :ok
  end

  @spec walk_step({non_neg_integer(), pos_integer()}, {Session.t(), [String.t()]}, [
          non_neg_integer()
        ]) ::
          {Session.t(), [String.t()]}
  defp walk_step({choice, index}, {session, keys}, choices) do
    {session, key} = KeyWalk.step(session, choice)
    keys = [key | keys]
    path = keys |> Enum.reverse() |> Enum.join(" · ")

    assert_defined(Session.model(session), path)

    replay = fn -> replay(Enum.take(choices, index)) end
    way_out = Explorer.with_session(replay, &Explorer.way_out(&1, replay))
    assert way_out == :ok, "no way out after #{path}: #{inspect(way_out)}"
    {session, keys}
  end

  @spec replay([non_neg_integer()]) :: Session.t()
  defp replay(choices) do
    Enum.reduce(choices, Registry.drive(Registry.home()), fn choice, session ->
      session |> KeyWalk.step(choice) |> elem(0)
    end)
  end

  @spec assert_defined(Model.t(), String.t()) :: :ok
  defp assert_defined(%Model{} = model, path) do
    if String.starts_with?(String.trim(model.pending_keys), "SPC") do
      assert model.which_key != nil,
             "after #{path} a leader sequence is pending with which-key closed: #{Model.signature(model)}"
    end

    :ok
  end
end
