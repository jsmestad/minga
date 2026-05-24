defmodule MingaGhostCursorsTest do
  use ExUnit.Case, async: true

  describe "extension module" do
    test "implements Minga.Extension behaviour" do
      assert MingaGhostCursors.name() == :minga_ghost_cursors
      assert MingaGhostCursors.description() == "Ghost cursor overlays for agent editing sessions"
      assert MingaGhostCursors.version() == "0.1.0"
    end

    test "declares ghost_cursor_follow command" do
      commands = MingaGhostCursors.__command_schema__()
      assert length(commands) == 1

      [{name, description, opts}] = commands
      assert name == :ghost_cursor_follow
      assert description == "Jump to the file the agent is editing"
      assert Keyword.fetch!(opts, :execute) == {MingaGhostCursors.Commands, :follow}
    end

    test "declares SPC a F keybinding" do
      keybinds = MingaGhostCursors.__keybind_schema__()
      assert length(keybinds) == 1

      [{mode, key, command, desc, _opts}] = keybinds
      assert mode == :normal
      assert key == "SPC a F"
      assert command == :ghost_cursor_follow
      assert desc == "Follow agent's file"
    end

    test "init returns ok" do
      assert {:ok, %{}} = MingaGhostCursors.init([])
    end

    test "child_spec starts the Tracker" do
      spec = MingaGhostCursors.child_spec([])
      assert spec.id == MingaGhostCursors.Tracker
      assert spec.start == {MingaGhostCursors.Tracker, :start_link, [[]]}
    end
  end
end
