defmodule MingaAgent.Tools.ShellJobPathTest do
  # The canonical shell callback saves dirty buffers through the global Buffer.Registry.
  use ExUnit.Case, async: false

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tools
  alias MingaAgent.Tools.Job
  alias MingaAgent.Tools.JobOwner

  @moduletag :tmp_dir

  defmodule ProbeBackend do
    @moduledoc false
    @behaviour MingaAgent.Tools.ProcessBackend

    @impl true
    def find(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

    @impl true
    def grep(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

    @impl true
    # Records each run in the command's cwd, which is the test's tmp_dir.
    def shell(command, cwd, _timeout_secs, opts) do
      File.write!(Path.join(cwd, "backend-runs"), command <> "\n", [:append])
      if report = Keyword.get(opts, :on_exit_status), do: report.(7)
      {:ok, "probe output\n[exit code: 7]"}
    end
  end

  setup %{tmp_dir: root} do
    quota =
      start_supervised!(
        Supervisor.child_spec({ArtifactQuota, root: root}, id: make_ref(), restart: :temporary)
      )

    store =
      start_supervised!(
        Supervisor.child_spec(
          {ArtifactStore, root: root, quota: quota, session_id: "job-path"},
          id: make_ref(),
          restart: :temporary
        )
      )

    owner =
      start_supervised!(
        Supervisor.child_spec({JobOwner, session_id: "job-path", notify: self()}, id: make_ref())
      )

    %{root: root, store: store, owner: owner}
  end

  test "a foreground shell call runs as a job and records its exit code", ctx do
    shell = shell_callback(ctx, ctx.owner)

    assert {:ok, _output} = shell.(%{"command" => "make test"})
    assert backend_runs(ctx) == ["make test"]

    assert [%Job{background?: false, status: {:terminal, :failed}, exit_code: 7}] =
             JobOwner.list_jobs(ctx.owner)
  end

  test "a background shell call returns the same job owner's handle", ctx do
    shell = shell_callback(ctx, ctx.owner)

    assert {:ok, message} = shell.(%{"command" => "make serve", "background" => true})
    assert [%Job{background?: true, id: id}] = JobOwner.list_jobs(ctx.owner)
    assert message =~ id
  end

  test "without a job owner the shell refuses instead of running the command", ctx do
    shell = shell_callback(ctx, nil)

    for background? <- [false, true] do
      assert {:error, message} = shell.(%{"command" => "make test", "background" => background?})
      assert message =~ "no job owner"
    end

    assert backend_runs(ctx) == []
  end

  defp backend_runs(ctx) do
    case File.read(Path.join(ctx.root, "backend-runs")) do
      {:ok, runs} -> String.split(runs, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp shell_callback(ctx, owner) do
    context =
      Context.new(
        project_root: ctx.root,
        artifact_store: ctx.store,
        capture_key: {:delivery, "checkpoint", "call-#{System.unique_integer([:positive])}"},
        metadata: %{process_backend: ProbeBackend, job_owner: owner}
      )

    shell = Enum.find(Tools.all(), &(&1.name == "shell"))
    MingaAgent.Tool.Spec.build_callback(shell, context)
  end
end
