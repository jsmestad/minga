Code.require_file("agent_recovery_provider.exs", __DIR__)
Code.require_file("../test/support/minga_agent/model_selection_fixture.ex", __DIR__)

defmodule Minga.Scripts.AgentRecoveryBaseline do
  @moduledoc """
  v0.1 Linux recovery corpus. Run with `bash scripts/agent_recovery_baseline`.
  Deterministic provider fixtures are non-live-model evidence, not coding-task acceptance.
  Violations remain failures; the driver never changes production state or expectations.
  """

  alias Minga.Recovery.ProviderFixture, as: Fixture
  alias MingaAgent.Runtime
  alias MingaAgent.Session
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.ToolCall

  @type context :: %{root: String.t(), project: String.t(), fixture: String.t()}
  @timeout 10_000
  @output :binary.copy("0123456789abcdef retained-output\n", 4096)

  @spec run() :: no_return()
  def run do
    root = System.fetch_env!("MINGA_RECOVERY_ROOT")
    true = System.get_env("HOME") == Path.join(root, "home")

    pins =
      File.read!(".tool-versions")
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [tool, version] = String.split(line)
        {tool, version}
      end)

    true = System.version() == hd(String.split(pins["elixir"], "-otp-"))

    otp_version =
      File.read!(
        Path.join([to_string(:code.root_dir()), "releases", System.otp_release(), "OTP_VERSION"])
      )
      |> String.trim()

    true = otp_version == pins["erlang"]
    true = File.dir?("/proc/self")
    {:ok, _} = Application.ensure_all_started(:minga)
    {:ok, :none} = Minga.Config.Options.set(:agent_tool_approval, :none)
    {:ok, false} = Minga.Config.Options.set(:agent_notifications, false)

    environment = %{
      corpus_version: "0.1",
      runtime_revision: System.fetch_env!("MINGA_RECOVERY_REVISION"),
      evidence_kind: "deterministic external provider fixture; NON-LIVE-MODEL",
      build: "MIX_ENV=dev; normal BEAM compilation, not a shipping release",
      elixir: System.version(),
      erlang: to_string(:erlang.system_info(:system_version)),
      otp_version: otp_version,
      os: command!("uname", ["-srmo"]),
      route: "openai:gpt-6.1-sol / Codex OAuth; in-process llm_client, no HTTP",
      credential_mode: "synthetic OAuth fixture, not a real account or credential",
      live_model_tokens: nil,
      live_model_cost: nil,
      live_provider_requests: 0,
      dependency_lock_sha256: hash(File.read!("mix.lock")),
      fixtures: fixture_hashes()
    }

    write_json(Path.join(root, "environment.json"), environment)

    results = [
      scenario(root, "cancel_descendants", &cancel_descendants/1),
      scenario(root, "delayed_response", &delayed_response/1),
      scenario(root, "retained_output", &retained_output/1),
      scenario(root, "human_edit", &human_edit/1)
    ]

    write_json(Path.join(root, "results.json"), %{environment: environment, scenarios: results})
    Enum.each(results, &IO.puts("#{&1.status}: #{&1.scenario}: #{inspect(&1.actual)}"))
    IO.puts("Raw evidence and scratch repositories retained: #{root}")
    System.halt(if Enum.all?(results, &(&1.status == "PASS")), do: 0, else: 1)
  end

  @spec scenario(String.t(), String.t(), (context() -> map())) :: map()
  defp scenario(root, name, exercise) do
    path = Path.join(root, name)
    project = Path.join(path, "project")
    File.mkdir_p!(project)
    command!("git", ["-c", "init.templateDir=", "init", "--quiet", project])
    File.write!(Path.join(project, "subject.txt"), "original\n")
    command!("git", ["-C", project, "add", "subject.txt"])

    command!("git", [
      "-C",
      project,
      "-c",
      "user.name=Recovery Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    ])

    Process.put(:evidence_path, Path.join(path, "events.ndjson"))
    Process.put(:sandbox_root, root)
    Process.put(:sessions, [])
    Process.put(:requests, 0)
    started = System.monotonic_time(:microsecond)

    context = %{
      root: path,
      project: project,
      fixture: Path.expand("test/fixtures/agent_recovery")
    }

    outcome =
      try do
        exercise.(context)
      rescue
        error ->
          %{
            status: "FAIL",
            actual: %{driver_error: sanitize(Exception.format(:error, error, __STACKTRACE__))},
            surviving_owned_processes: nil,
            surviving_owned_processes_after_cleanup: nil
          }
      catch
        kind, reason ->
          %{
            status: "FAIL",
            actual: %{driver_error: sanitize(inspect({kind, reason}))},
            surviving_owned_processes: nil,
            surviving_owned_processes_after_cleanup: nil
          }
      after
        Enum.each(Process.get(:sessions), fn {id, pid, monitor} ->
          result = Runtime.stop_session(id)
          record("stop_session", %{id: id, result: inspect(result)})
          await(fn message -> match?({:DOWN, ^monitor, :process, ^pid, _}, message) end)
        end)
      end

    File.write!(
      Path.join(path, "repository.diff"),
      command!("git", ["-C", project, "diff", "--binary"])
    )

    File.write!(
      Path.join(path, "repository.status"),
      command!("git", ["-C", project, "status", "--porcelain=v1", "--untracked-files=all"])
    )

    result =
      Map.merge(
        %{
          scenario: name,
          expected: expected(name),
          prohibited_effects: prohibited(name),
          canonical_owners: owners(name),
          interventions: [],
          surviving_owned_processes: nil,
          surviving_owned_processes_after_cleanup: nil,
          elapsed_ms: (System.monotonic_time(:microsecond) - started) / 1000,
          provider_requests: Process.get(:requests),
          artifact_bytes: artifact_bytes(path),
          repository_files: repository_files(project),
          accepted_completion: false,
          live_model_tokens: nil,
          live_model_cost: nil
        },
        outcome
      )

    write_json(Path.join(path, "result.json"), result)
    result
  end

  @spec start(context()) :: {String.t(), pid()}
  defp start(context) do
    oauth_path = Path.join(context.root, "fixture-oauth.json")

    payload =
      MingaAgent.OAuth.oauth_file_payload(%{
        access: "fixture-access",
        refresh: "fixture-refresh",
        expires: System.system_time(:millisecond) + 3_600_000,
        account_id: "fixture-account"
      })

    write_json(oauth_path, payload)

    credential_opts = [
      env: %{},
      config_dir: Path.join(context.root, "credentials"),
      oauth_path: oauth_path
    ]

    resolver_opts =
      ModelSelectionFixture.resolver_opts(model_id: "gpt-6.1-sol")
      |> Keyword.delete(:credential_snapshot)

    opts = [
      provider: MingaAgent.Providers.Native,
      model_name: "openai:gpt-6.1-sol",
      workdir: context.project,
      session_store_dir: Path.join(context.root, "sessions"),
      hooks_enabled?: false,
      credentials_snapshot_fn: fn -> MingaAgent.Credentials.snapshot(credential_opts) end,
      provider_opts: [
        model: "openai:gpt-6.1-sol",
        model_resolver_opts: resolver_opts,
        credential_opts: credential_opts,
        project_root: context.project,
        mcp_enabled?: false,
        config: %MingaAgent.Config{compaction_threshold: nil, tool_approval: :none},
        llm_client: Fixture.client(self()),
        max_retries: 0
      ]
    ]

    {:ok, id, pid} = Runtime.start_session(opts)
    Process.put(:sessions, [{id, pid, Process.monitor(pid)} | Process.get(:sessions)])
    :ok = Session.subscribe(pid)
    record("session_started", %{id: id})
    {id, pid}
  end

  @spec cancel_descendants(context()) :: map()
  defp cancel_descendants(context) do
    socket = Path.join(context.root, "control.sock")
    helper = Path.join(context.fixture, "process_fixture.py")

    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 16_384},
        args: [helper, "observe", socket]
      ])

    try do
      %{"event" => "listening"} = port_json(port)
      {id, session} = start(context)
      :ok = Runtime.send_prompt(id, "Run the deterministic verification fixture until cancelled.")
      request = request()

      command =
        "exec python3 #{quote_shell(helper)} parent #{quote_shell(socket)} #{quote_shell(Path.join(context.project, "late-effect.txt"))}"

      respond(
        request,
        Fixture.tool("verification", "shell", %{"command" => command, "timeout" => 30})
      )

      %{"event" => "tree_ready", "owned" => owned} = port_json(port)
      record("owned_processes_before_abort", owned)
      :ok = Runtime.abort(id)
      :idle = Session.status(session)
      true = Port.command(port, "inspect\n")
      %{"event" => "observed"} = observed = port_json(port)
      {^port, {:exit_status, 0}} = await(&match?({^port, {:exit_status, _}}, &1))
      sentinel = File.exists?(Path.join(context.project, "late-effect.txt"))

      pass =
        observed["survivors"] == [] and not sentinel and observed["survivors_after_cleanup"] == []

      %{
        status: verdict(pass),
        actual: %{observation: observed, sentinel_written: sentinel},
        surviving_owned_processes: observed["survivors"],
        surviving_owned_processes_after_cleanup: observed["survivors_after_cleanup"],
        interventions: observed["interventions"]
      }
    after
      finish_observer(port)
    end
  end

  @spec delayed_response(context()) :: map()
  defp delayed_response(context) do
    {id, session} = start(context)
    :ok = Runtime.send_prompt(id, "Append once, then await the next response.")
    first = request()
    pidfile = Path.join(context.root, "append-process.json")

    command =
      "exec python3 #{quote_shell(Path.join(context.fixture, "process_fixture.py"))} append #{quote_shell(pidfile)} completed.txt"

    call = Fixture.tool("append-once", "shell", %{"command" => command})
    respond(first, call)
    old = {old_pid, _token, _model, _messages} = request()
    true = File.read!(Path.join(context.project, "completed.txt")) == "once\n"
    monitor = Process.monitor(old_pid)
    :ok = Runtime.abort(id)
    await(fn message -> match?({:DOWN, ^monitor, :process, ^old_pid, _}, message) end)
    :ok = Runtime.send_prompt(id, "Replacement request: respond only replacement-complete.")
    replacement = {new_pid, _token, _model, _messages} = request()
    true = old_pid != new_pid
    respond(old, call ++ Fixture.text("STALE-CONTENT"))

    record("delayed_response_after_abort", %{
      old_consumer_down: true,
      replacement_consumer: inspect(new_pid)
    })

    respond(replacement, Fixture.text("replacement-complete"))
    idle(session)
    messages = Session.messages(session)
    transcript = inspect(messages, limit: :infinity, printable_limit: :infinity)
    File.write!(Path.join(context.root, "transcript.txt"), sanitize(transcript))
    content = File.read!(Path.join(context.project, "completed.txt"))
    replacement_finished = Enum.member?(messages, {:assistant, "replacement-complete"})
    observation = observe_process(context, pidfile)

    pass =
      content == "once\n" and replacement_finished and not (transcript =~ "STALE-CONTENT") and
        Session.status(session) == :idle and observation["survivors"] == []

    Map.merge(process_result(observation), %{
      status: verdict(pass),
      accepted_completion: pass,
      actual: %{
        completed_effect_bytes: content,
        replacement_finished: replacement_finished,
        stale_text_installed: transcript =~ "STALE-CONTENT",
        cancelled_consumer_terminated: true,
        process_observation: observation
      }
    })
  end

  @spec retained_output(context()) :: map()
  defp retained_output(context) do
    {id, session} = start(context)
    :ok = Runtime.send_prompt(id, "Run the known-output fixture and retrieve all retained bytes.")
    pidfile = Path.join(context.root, "output-process.json")

    respond(
      request(),
      Fixture.tool("output", "shell", %{
        "command" =>
          "exec python3 #{quote_shell(Path.join(context.fixture, "output_fixture.py"))} #{quote_shell(pidfile)}"
      })
    )

    next = request()
    output = tool_output(session, "output")
    File.write!(Path.join(context.root, "known-output.bin"), @output)
    File.write!(Path.join(context.root, "displayed-output.txt"), output.view)
    record("output_contract", output)
    reference = output.reference
    true = reference != nil

    reference_args =
      reference
      |> Map.from_struct()
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    {last, pages} =
      Enum.reduce(0..div(reference.bytes - 1, 51_200), {next, []}, fn page, {pending, acc} ->
        call_id = "fetch-#{page}"
        count = min(51_200, reference.bytes - page * 51_200)

        args = %{
          "reference" => reference_args,
          "unit" => "bytes",
          "start" => page * 51_200,
          "count" => count
        }

        respond(pending, Fixture.tool(call_id, "fetch_output", args))
        pending = request()
        {pending, [tool_output(session, call_id).view | acc]}
      end)

    recovered = pages |> Enum.reverse() |> IO.iodata_to_binary()
    File.write!(Path.join(context.root, "recovered-output.bin"), recovered)
    respond(last, Fixture.text("output-retrieval-complete"))
    idle(session)
    observation = observe_process(context, pidfile)

    pass =
      byte_size(output.view) < byte_size(@output) and output.capture == :complete and
        recovered == @output and hash(recovered) == hash(@output) and
        observation["survivors"] == []

    Map.merge(process_result(observation), %{
      status: verdict(pass),
      actual: %{
        expected_bytes: byte_size(@output),
        expected_sha256: hash(@output),
        displayed_bytes: byte_size(output.view),
        capture: inspect(output.capture),
        presentation: inspect(output.presentation),
        retained_bytes: reference.bytes,
        retained_sha256: reference.sha256,
        recovered_bytes: byte_size(recovered),
        recovered_sha256: hash(recovered),
        complete_byte_match: recovered == @output,
        process_observation: observation
      }
    })
  end

  @spec human_edit(context()) :: map()
  defp human_edit(context) do
    {id, session} = start(context)

    :ok =
      Runtime.send_prompt(
        id,
        "Read subject.txt, then prepare a whole-file edit replacing original with agent."
      )

    respond(request(), Fixture.tool("read-before-edit", "read_file", %{"path" => "subject.txt"}))
    prepared = request()
    original = tool_output(session, "read-before-edit")
    record("prepared_edit_source", original)

    edit =
      Fixture.tool("prepared-edit", "write_file", %{
        "path" => "subject.txt",
        "content" => "agent\n"
      })

    File.write!(Path.join(context.project, "subject.txt"), "human\n")
    record("human_edit_barrier", %{disk_bytes: "human\n", prepared_bytes: "agent\n"})
    respond(prepared, edit)
    next = request()

    {:tool_call, tool} =
      Enum.find(Session.messages(session), fn entry ->
        match?({:tool_call, %ToolCall{id: "prepared-edit"}}, entry)
      end)

    respond(next, Fixture.text("edit-attempt-complete"))
    idle(session)
    disk = File.read!(Path.join(context.project, "subject.txt"))

    buffer =
      case Minga.Buffer.pid_for_path(Path.join(context.project, "subject.txt")) do
        {:ok, pid} -> Minga.Buffer.content(pid)
        :not_found -> nil
      end

    conflict =
      tool.status == :error and
        Regex.match?(
          ~r/stale (?:source|revision)|revision (?:mismatch|conflict)|merge conflict|conflict detected/i,
          tool.result
        )

    pass = disk == "human\n" and buffer in [nil, "human\n"] and conflict

    %{
      status: verdict(pass),
      surviving_owned_processes: [],
      surviving_owned_processes_after_cleanup: [],
      interventions: [
        "human wrote subject.txt after response preparation and before tool dispatch"
      ],
      actual: %{
        disk_bytes: disk,
        buffer_bytes: buffer,
        conflict_reported: conflict,
        tool_status: inspect(tool.status),
        tool_result: sanitize(tool.result),
        process_observation:
          "No external command workload: read_file and write_file only; Session shutdown is monitored."
      }
    }
  end

  @spec observe_process(context(), String.t()) :: map()
  defp observe_process(context, pidfile) do
    observation =
      command!("python3", [Path.join(context.fixture, "process_fixture.py"), "inspect", pidfile])
      |> JSON.decode!()

    record("owned_workload_process", observation)
    observation
  end

  @spec process_result(map()) :: map()
  defp process_result(observation) do
    %{
      surviving_owned_processes: observation["survivors"],
      surviving_owned_processes_after_cleanup: observation["survivors_after_cleanup"],
      interventions: observation["interventions"]
    }
  end

  @spec request() :: Fixture.request()
  defp request do
    {:recovery_request, request} = await(&match?({:recovery_request, _}, &1))
    Process.put(:requests, Process.get(:requests) + 1)
    request
  end

  @spec respond(Fixture.request(), [ReqLLM.StreamChunk.t()]) :: :ok
  defp respond(request, chunks) do
    record("fixture_response", chunks)
    Fixture.deliver(request, chunks)
  end

  @spec idle(pid()) :: :ok
  defp idle(session) do
    await(&match?({:agent_event, ^session, {:resumable_boundary, _}}, &1))
    :idle = Session.status(session)
    :ok
  end

  @spec tool_output(pid(), String.t()) :: MingaAgent.Tool.Output.t()
  defp tool_output(session, id) do
    {:tool_call, %ToolCall{output: output}} =
      Enum.find(Session.messages(session), &match?({:tool_call, %ToolCall{id: ^id}}, &1))

    output
  end

  @spec await((term() -> boolean())) :: term()
  defp await(predicate), do: await(predicate, System.monotonic_time(:millisecond) + @timeout)

  @spec await((term() -> boolean()), integer()) :: term()
  defp await(predicate, deadline) do
    receive do
      message ->
        record("received", message)
        if predicate.(message), do: message, else: await(predicate, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> raise "explicit barrier timed out"
    end
  end

  @spec finish_observer(port()) :: :ok
  defp finish_observer(port) do
    case Port.info(port) do
      nil ->
        :ok

      _info ->
        Port.command(port, "cleanup\n")
        {^port, {:exit_status, code}} = await(&match?({^port, {:exit_status, _}}, &1))
        record("observer_cleanup_exit", code)
        if code != 0, do: raise("observer cleanup failed with exit #{code}")
        :ok
    end
  end

  @spec port_json(port()) :: map()
  defp port_json(port) do
    {^port, {:data, {:eol, line}}} = await(&match?({^port, {:data, {:eol, _}}}, &1))
    JSON.decode!(line)
  end

  @spec record(String.t(), term()) :: :ok
  defp record(event, data) do
    line =
      JSON.encode!(%{
        event: event,
        monotonic_us: System.monotonic_time(:microsecond),
        data: sanitize(inspect(data, limit: :infinity, printable_limit: :infinity))
      })

    File.write!(Process.get(:evidence_path), line <> "\n", [:append])
  end

  @spec sanitize(String.t()) :: String.t()
  defp sanitize(text),
    do:
      text
      |> String.replace(Process.get(:sandbox_root), "$SANDBOX")
      |> String.replace(File.cwd!(), "$SOURCE")

  @spec expected(String.t()) :: String.t()
  defp expected("cancel_descendants"),
    do: "All owned shell descendants stop within 1000ms of abort; no late-effect.txt."

  defp expected("delayed_response"),
    do:
      "completed.txt contains exactly once\\n; replacement completes without stale text or duplicate effects."

  defp expected("retained_output"),
    do:
      "Displayed output is shortened; fetch_output recovers all #{byte_size(@output)} known bytes with identical SHA-256."

  defp expected("human_edit"),
    do: "subject.txt and any buffer preserve human\\n; stale whole-file edit reports a conflict."

  @spec prohibited(String.t()) :: [String.t()]
  defp prohibited("cancel_descendants"),
    do: ["live owned descendants after cancellation deadline", "post-cancel sentinel write"]

  defp prohibited("delayed_response"),
    do: ["second append", "stale response enters replacement continuation"]

  defp prohibited("retained_output"),
    do: [
      "missing retained bytes",
      "source replay instead of retained retrieval",
      "false complete capture"
    ]

  defp prohibited("human_edit"),
    do: ["human disk or buffer bytes overwritten", "silent success for stale edit"]

  @spec owners(String.t()) :: [String.t()]
  defp owners("cancel_descendants"),
    do: ["#2843 Shell process-tree lifecycle", "#2839 effect-worker cancellation"]

  defp owners("delayed_response"), do: ["#3428 Session/Native request lifecycle"]
  defp owners("retained_output"), do: ["#3432 retained shell output"]
  defp owners("human_edit"), do: ["#3436 revision-checked mutation"]

  @spec verdict(boolean()) :: String.t()
  defp verdict(true), do: "PASS"
  defp verdict(false), do: "FAIL"

  @spec hash(binary()) :: String.t()
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @spec write_json(String.t(), term()) :: :ok
  defp write_json(path, data), do: File.write!(path, JSON.encode!(data) <> "\n")

  @spec command!(String.t(), [String.t()]) :: String.t()
  defp command!(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> raise "#{command} failed (#{code}): #{output}"
    end
  end

  @spec quote_shell(String.t()) :: String.t()
  defp quote_shell(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  @spec artifact_bytes(String.t()) :: non_neg_integer()
  defp artifact_bytes(path),
    do:
      Path.wildcard(Path.join(path, "**/*"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.reduce(0, &(File.stat!(&1).size + &2))

  @spec repository_files(String.t()) :: map()
  defp repository_files(project) do
    Path.wildcard(Path.join(project, "*"))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path ->
      {Path.basename(path), %{bytes: File.stat!(path).size, sha256: hash(File.read!(path))}}
    end)
  end

  @spec fixture_hashes() :: map()
  defp fixture_hashes do
    [
      "scripts/agent_recovery_baseline",
      "scripts/agent_recovery_baseline.exs",
      "test/support/minga_agent/model_selection_fixture.ex",
      "scripts/agent_recovery_provider.exs"
      | Path.wildcard("test/fixtures/agent_recovery/*.py")
    ]
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, hash(File.read!(&1))})
  end
end

Minga.Scripts.AgentRecoveryBaseline.run()
