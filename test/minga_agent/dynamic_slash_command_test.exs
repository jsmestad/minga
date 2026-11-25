defmodule MingaAgent.DynamicSlashCommandTest do
  # Spawns a real OS process through System.cmd/3.
  use ExUnit.Case, async: false

  alias MingaAgent.DynamicSlashCommand

  @moduletag timeout: 5_000

  test "runs the declared executable with normalized arguments" do
    assert {"hello", 0} = DynamicSlashCommand.run("/usr/bin/printf", ["hello"])
  end

  test "runs in the directory it is given, so a relative argument means a file in the project" do
    directory =
      Path.join(System.tmp_dir!(), "minga_slash_cwd_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    File.write!(Path.join(directory, "note.txt"), "from the project")

    assert {"from the project", 0} = DynamicSlashCommand.run("/bin/cat", ["note.txt"], directory)
  end
end
