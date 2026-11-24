defmodule MingaAgent.Tools.ShellJobPathTest do
  # The canonical shell callback saves dirty buffers through the global Buffer.Registry.
  use ExUnit.Case, async: false

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.Session
  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Test.JobSessionStub
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tools

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

    session = start_supervised!({JobSessionStub, []}, id: make_ref())

    %{root: root, store: store, session: session}
  end

  test "a foreground shell call runs as a job the session records with its exit code", ctx do
    shell = shell_callback(ctx, JobSessionStub.metadata(ctx.session))

    assert {:ok, _output} = shell.(%{"command" => "make test"})
    assert backend_runs(ctx) == ["make test"]

    assert [%Record{background?: false, status: {:terminal, :failed, 7}, notice: :none}] =
             Session.jobs(ctx.session)
  end

  test "a background shell call returns the handle the session admitted", ctx do
    shell = shell_callback(ctx, JobSessionStub.metadata(ctx.session))

    assert {:ok, message} = shell.(%{"command" => "make serve", "background" => true})
    assert [%Record{background?: true, id: id}] = Session.jobs(ctx.session)
    assert message =~ id
  end

  test "job_status and job_output read the session's record", ctx do
    metadata = JobSessionStub.metadata(ctx.session)
    assert {:ok, _output} = shell_callback(ctx, metadata).(%{"command" => "make test"})
    [%Record{id: id}] = Session.jobs(ctx.session)

    assert {:ok, status} = tool_callback(ctx, "job_status", metadata).(%{"job_id" => id})
    assert status =~ "Status: failed"
    assert status =~ "Exit code: 7"

    assert {:ok, output} = tool_callback(ctx, "job_output", metadata).(%{"job_id" => id})
    assert output =~ "probe output"
    assert output =~ "Full output reference for fetch_output"
  end

  test "a background job captures under its own key, apart from the start call's result", ctx do
    metadata = JobSessionStub.metadata(ctx.session)
    capture_key = {:delivery, "checkpoint", "call-background"}

    assert {:ok, _message} =
             shell_callback(ctx, metadata, capture_key).(%{
               "command" => "make build",
               "background" => true
             })

    [%Record{id: id}] = Session.jobs(ctx.session)
    assert {:ok, %Record{output_ref: reference}} = await_terminal(ctx.session, id)
    assert %MingaAgent.Tool.Output.Reference{} = reference

    assert {:ok, stored} =
             ArtifactStore.lookup_delivery(ctx.store, {:delivery, "checkpoint", "job:" <> id})

    assert stored.reference == reference
    assert {:error, :unknown_delivery} = ArtifactStore.lookup_delivery(ctx.store, capture_key)
  end

  # The background task settles asynchronously, so poll the public query.
  defp await_terminal(session, id, attempts \\ 100) do
    case Session.job(session, id) do
      {:ok, %Record{status: :running}} when attempts > 0 ->
        Process.sleep(10)
        await_terminal(session, id, attempts - 1)

      result ->
        result
    end
  end

  test "without an owning session the shell refuses instead of running the command", ctx do
    no_session = %{parent_session: self()}

    for metadata <- [%{}, no_session], background? <- [false, true] do
      shell = shell_callback(ctx, metadata)
      assert {:error, message} = shell.(%{"command" => "make test", "background" => background?})
      assert message =~ "no owning agent session"
    end

    assert backend_runs(ctx) == []
    refute_received {:"$gen_call", _from, _request}
  end

  defp backend_runs(ctx) do
    case File.read(Path.join(ctx.root, "backend-runs")) do
      {:ok, runs} -> String.split(runs, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp shell_callback(ctx, metadata, capture_key \\ nil),
    do: tool_callback(ctx, "shell", metadata, capture_key)

  defp tool_callback(ctx, name, metadata, capture_key \\ nil) do
    context =
      Context.new(
        project_root: ctx.root,
        artifact_store: ctx.store,
        capture_key:
          capture_key || {:delivery, "checkpoint", "call-#{System.unique_integer([:positive])}"},
        metadata: Map.put(metadata, :process_backend, ProbeBackend)
      )

    spec = Enum.find(Tools.all(), &(&1.name == name))
    MingaAgent.Tool.Spec.build_callback(spec, context)
  end
end
