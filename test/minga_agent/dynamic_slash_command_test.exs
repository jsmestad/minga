defmodule MingaAgent.DynamicSlashCommandTest do
  # Spawns a real OS process through System.cmd/3.
  use ExUnit.Case, async: false

  alias MingaAgent.DynamicSlashCommand

  @moduletag timeout: 5_000

  test "runs the declared executable with normalized arguments" do
    assert {"hello", 0} = DynamicSlashCommand.run("/usr/bin/printf", ["hello"])
  end
end
