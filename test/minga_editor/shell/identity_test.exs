defmodule MingaEditor.Shell.IdentityTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Identity

  test "id, module, source, and generation define one exact registration identity" do
    entry = entry()
    identity = Identity.new(entry)

    assert Identity.matches?(entry, entry)
    assert Identity.matches?(identity, entry)
    assert Identity.matches?(entry, identity)

    refute Identity.matches?(identity, %{entry | id: :replacement})
    refute Identity.matches?(identity, %{entry | module: String})
    refute Identity.matches?(identity, %{entry | source: {:extension, :replacement}})
    refute Identity.matches?(identity, %{entry | generation: entry.generation + 1})
  end

  test "presentation metadata does not change registration identity" do
    entry = entry()

    changed_metadata = %Entry{
      entry
      | display_name: "Renamed",
        description: "Updated description",
        capabilities: [:gui, :tui],
        default?: true
    }

    assert Identity.matches?(entry, changed_metadata)
    assert Identity.new(entry) == Identity.new(changed_metadata)
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
