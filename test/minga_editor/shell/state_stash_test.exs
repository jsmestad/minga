defmodule MingaEditor.Shell.StateStashTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.StateStash

  test "restore returns stored state for the matching registry identity" do
    entry = entry()
    stash = StateStash.new(entry, %{count: 2})

    assert StateStash.restore(stash, entry) == {:ok, %{count: 2}}
  end

  test "module, source, generation, and id mismatches never restore state" do
    entry = entry()
    stash = StateStash.new(entry, %{count: 2})

    mismatches = [
      %{entry | module: String},
      %{entry | source: {:extension, :replacement}},
      %{entry | generation: entry.generation + 1},
      %{entry | id: :replacement}
    ]

    Enum.each(mismatches, fn mismatch ->
      assert StateStash.restore(stash, mismatch) == :mismatch
    end)
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
