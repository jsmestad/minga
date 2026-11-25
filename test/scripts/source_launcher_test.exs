defmodule Minga.SourceLauncherTest do
  @moduledoc "The source launcher starts Mix from the source tree and still opens what the caller asked for."

  # Not async: these tests spawn real shell processes, which can hit the BEAM child-process race.
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  @source_tree Path.expand("../..", __DIR__)
  @launcher Path.join(@source_tree, "bin/lib/minga")

  setup do
    tmp_dir = File.cd!(System.tmp_dir!(), &File.cwd!/0)
    root = Path.join(tmp_dir, "minga-source-launcher-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    fake_bin = Path.join(root, "bin")
    File.mkdir_p!(workspace)
    File.mkdir_p!(fake_bin)

    # Stands in for Mix: records where it runs and what it was given, then exits as the test asks.
    File.write!(Path.join(fake_bin, "mix"), """
    #!/bin/sh
    {
      printf 'cwd=%s\\n' "$(pwd -P)"
      printf 'launch_dir=%s\\n' "$MINGA_LAUNCH_DIR"
      for arg in "$@"; do printf 'arg=%s\\n' "$arg"; done
    } > "$MINGA_TEST_MIX_LOG"
    echo "output of the editor: $MINGA_TEST_MIX_SAYS"
    exit "${MINGA_TEST_MIX_STATUS:-0}"
    """)

    File.chmod!(Path.join(fake_bin, "mix"), 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    env = [
      {"PATH", fake_bin <> ":" <> System.get_env("PATH")},
      {"XDG_DATA_HOME", Path.join(root, "data")},
      {"MINGA_TEST_MIX_LOG", Path.join(root, "mix.log")},
      {"MINGA_SKIP_NATIVE_LAUNCH_BUILD", "1"},
      {"MINGA_TTY", "/dev/null"}
    ]

    {:ok, root: root, workspace: workspace, env: env}
  end

  defp run_launcher(context, args, extra_env \\ []) do
    System.cmd(@launcher, args,
      cd: context.workspace,
      env: context.env ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp mix_log(context) do
    context.root
    |> Path.join("mix.log")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  test "Mix runs in the source tree, and the caller's directory and arguments travel with it",
       context do
    assert {"", 0} = run_launcher(context, ["notes/today.md"])

    {:ok, source_tree} = Minga.Project.Root.canonical_path(@source_tree)
    {:ok, workspace} = Minga.Project.Root.canonical_path(context.workspace)

    assert mix_log(context) == [
             "cwd=#{source_tree}",
             "launch_dir=#{workspace}",
             "arg=minga",
             "arg=--",
             "arg=notes/today.md"
           ]
  end

  test "a start that fails says so on the terminal, with the end of the log", context do
    {output, status} =
      run_launcher(context, ["notes/today.md"], [
        {"MINGA_TEST_MIX_STATUS", "3"},
        {"MINGA_TEST_MIX_SAYS", "could not start"}
      ])

    assert status == 3
    assert output =~ "minga: the editor exited with status 3."
    assert output =~ "output of the editor: could not start"
  end

  test "a start that succeeds prints nothing: the editor owns the terminal", context do
    assert {"", 0} = run_launcher(context, [], [{"MINGA_TEST_MIX_SAYS", "drawn by the editor"}])

    log = File.read!(Path.join([context.root, "data", "minga", "minga.log"]))
    assert log =~ "output of the editor: drawn by the editor"
  end
end
