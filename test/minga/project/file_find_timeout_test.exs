defmodule Minga.Project.FileFindTimeoutTest do
  @moduledoc "Tests the bounded synchronous FileFind wait path with a controlled executable."

  # This test spawns a real external process, which requires serialized execution.
  use ExUnit.Case, async: false

  alias Minga.Project.FileFind
  alias Minga.Project.FileFind.Worker

  @moduletag :tmp_dir
  @moduletag timeout: 10_000

  test "direct discovery wait times out and cancels its worker", %{tmp_dir: tmp_dir} do
    script = Path.join(tmp_dir, "slow-discovery.sh")
    File.write!(script, "#!/bin/sh\nsleep 60\n")
    File.chmod!(script, 0o755)
    command = {System.find_executable("sh"), [script], tmp_dir}
    {:ok, worker} = Worker.start(self(), command, fn output, status -> {output, status} end)

    assert FileFind.await_result(worker, 20) ==
             {:error, "Project file discovery timed out"}
  end
end
