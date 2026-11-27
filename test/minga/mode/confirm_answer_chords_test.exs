defmodule Minga.Mode.ConfirmAnswerChordsTest do
  @moduledoc """
  A confirmation is answered by a letter pressed without Control, Alt or Command.

  Without enhanced key reporting a terminal sends Esc followed by `y` as Alt+y when both arrive together. Esc means cancel, so that key must never confirm.
  """

  use ExUnit.Case, async: true

  alias Minga.Editing.Search.Match
  alias Minga.Mode.DeleteConfirm
  alias Minga.Mode.DeleteConfirmState
  alias Minga.Mode.ExtensionConfirm
  alias Minga.Mode.ExtensionConfirmState
  alias Minga.Mode.SubstituteConfirm
  alias Minga.Mode.SubstituteConfirmState
  alias Minga.Mode.ToolConfirm
  alias Minga.Mode.ToolConfirmState

  @chords [{0x02, "Control"}, {0x04, "Alt"}, {0x08, "Command"}, {0x05, "Alt and Shift"}]
  @escape 27

  defp cases do
    update = %{
      name: :ext,
      source_type: :git,
      old_ref: "a",
      new_ref: "b",
      commit_count: 1,
      branch: "main",
      pinned: false
    }

    delete = DeleteConfirmState.new("/tmp/foo.ex", "foo.ex", false, {1, 0, 123, :regular})

    [
      {DeleteConfirm, delete, [?y, ?n]},
      {DeleteConfirm, DeleteConfirmState.to_permanent(delete), [?y, ?n]},
      {ToolConfirm, %ToolConfirmState{pending: [:pyright], declined: MapSet.new()}, [?y, ?n]},
      {SubstituteConfirm, SubstituteConfirmState.new([Match.new(0, 0, 3)], "foo", "bar", "foo"),
       [?y, ?n, ?a, ?q]},
      {ExtensionConfirm, %ExtensionConfirmState{updates: [update]}, [?Y, ?n, ?d, ?q]}
    ]
  end

  test "an answer letter held with a chord modifier is ignored in every confirmation" do
    for {mode, state, letters} <- cases(), letter <- letters, {mods, name} <- @chords do
      assert {:continue, ^state} = mode.handle_key({letter, mods}, state),
             "#{inspect(mode)}: #{name}+#{<<letter::utf8>>} must not answer"
    end
  end

  test "the same letters answer when pressed alone" do
    for {mode, state, letters} <- cases(), letter <- letters do
      refute match?({:continue, ^state}, mode.handle_key({letter, 0}, state)),
             "#{inspect(mode)}: #{<<letter::utf8>>} must answer"
    end
  end

  test "Esc leaves a confirmation with any modifier" do
    for {mode, state, _letters} <- cases(), mods <- [0, 0x04] do
      refute match?({:continue, ^state}, mode.handle_key({@escape, mods}, state))
    end
  end
end
