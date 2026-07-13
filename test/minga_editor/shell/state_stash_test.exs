defmodule MingaEditor.Shell.StateStashTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.StateStash

  test "restore returns stored state for the matching registry identity" do
    entry = entry()
    stash = StateStash.new(entry, %{count: 2})

    assert StateStash.restore(stash, entry) == {:ok, %{count: 2}}
  end

  test "transform updates state while preserving registry identity metadata" do
    entry = entry()
    stash = StateStash.new(entry, %{count: 2})

    assert {:updated, updated} =
             StateStash.transform(stash, entry, fn state ->
               {:updated, Map.update!(state, :count, &(&1 + 1))}
             end)

    assert updated.state == %{count: 3}
    assert updated.id == stash.id
    assert updated.module == stash.module
    assert updated.source == stash.source
    assert updated.generation == stash.generation
  end

  test "transform reports unchanged without rebuilding the stash" do
    entry = entry()
    stash = StateStash.new(entry, %{count: 2})

    assert StateStash.transform(stash, entry, fn _state -> :unchanged end) ==
             {:unchanged, stash}
  end

  test "module, source, generation, and id mismatches never invoke the transformation" do
    entry = entry()
    stash = StateStash.new(entry, %{count: 2})
    test_pid = self()

    mismatches = [
      %{entry | module: String},
      %{entry | source: {:extension, :replacement}},
      %{entry | generation: entry.generation + 1},
      %{entry | id: :replacement}
    ]

    Enum.each(mismatches, fn mismatch ->
      assert StateStash.restore(stash, mismatch) == :mismatch

      assert StateStash.transform(stash, mismatch, fn state ->
               send(test_pid, {:invoked, mismatch})
               {:updated, state}
             end) == :mismatch
    end)

    refute_receive {:invoked, _mismatch}
  end

  @spec entry() :: Entry.t()
  defp entry do
    %Entry{
      id: :fake,
      source: {:extension, :fake},
      module: MingaEditor.Test.FakeShell,
      display_name: "Fake",
      description: "Fake shell",
      capabilities: [:tui],
      generation: 7
    }
  end
end
