defmodule Minga.RuntimeDataPathsTest do
  use ExUnit.Case, async: true

  alias Minga.Session

  @moduletag :tmp_dir

  test "default state paths follow the runtime XDG data home", %{tmp_dir: tmp_dir} do
    elixir = System.find_executable("elixir")
    assert elixir != nil

    code = """
    IO.puts(Minga.Session.session_file())
    IO.puts(Minga.Session.Swap.swap_dir())
    IO.puts(Minga.Session.EventRecorder.db_path())
    IO.puts(MingaAgent.EventLog.db_path())
    """

    {output, 0} =
      System.cmd(elixir, ["-pa", Path.dirname(to_string(:code.which(Session))), "-e", code],
        env: [{"XDG_DATA_HOME", tmp_dir}],
        stderr_to_stdout: true
      )

    assert String.split(output, "\n", trim: true) == [
             Path.join(tmp_dir, "minga/sessions/session.json"),
             Path.join(tmp_dir, "minga/swap"),
             Path.join(tmp_dir, "minga/events.db"),
             Path.join(tmp_dir, "minga/agent_events.db")
           ]
  end
end
