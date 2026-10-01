defmodule MingaAgent.Providers.NativeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Git.Stub, as: GitStub
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.ProjectView
  alias MingaAgent.Event
  alias MingaAgent.TurnUsage
  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session.Request
  alias MingaAgent.Tool.Spec
  alias MingaAgent.Test.RecordingProcessBackend
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.Tools
  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.StreamResponse.MetadataHandle

  @moduletag :tmp_dir
  # Multi-turn agent loops with real Task spawning (~400-800ms per test).
  # Excluded from test.llm; runs in test.heavy and full suite.
  @moduletag :heavy

  # ── Test helpers ────────────────────────────────────────────────────────────

  # Builds a fake llm_client function that returns a StreamResponse yielding
  # the given chunks. This lets us test the full agent loop without hitting
  # any real LLM API.
  defp fake_llm_client(chunks, usage \\ %{}) do
    fn _model, _messages, _opts ->
      build_stream_response(chunks, usage)
    end
  end

  defp build_stream_response(chunks, usage \\ %{}, response_metadata \\ %{}) do
    # MetadataHandle is a GenServer that returns metadata when awaited.
    metadata = Map.merge(%{usage: usage, finish_reason: :stop}, response_metadata)
    {:ok, handle} = MetadataHandle.start_link(fn -> metadata end)

    stream_response = %ReqLLM.StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: ModelSelectionFixture.selection().request_model,
      context: ReqLLM.Context.new()
    }

    {:ok, stream_response}
  end

  defp blocking_text_stream do
    parent = self()
    ref = make_ref()

    stream =
      Stream.resource(
        fn ->
          send(parent, {:blocking_stream_waiting, ref})
          ref
        end,
        fn ^ref ->
          receive do
            {^ref, :emit, text} -> {[ReqLLM.StreamChunk.text(text)], ref}
            {^ref, :halt} -> {:halt, ref}
          end
        end,
        fn _ -> :ok end
      )

    {stream, ref}
  end

  defp assert_streaming_started(pid, stream_ref) do
    assert_receive {:agent_provider_event, %Event.AgentStart{}}, 500
    assert_receive {:blocking_stream_waiting, ^stream_ref}, 500
    assert {:ok, %{is_streaming: true}} = Native.get_state(pid)
  end

  defp send_prompt(pid, content) do
    messages = Process.get({__MODULE__, pid, :messages}, [])
    revision = Process.get({__MODULE__, pid, :revision}, 0)
    identity = Integer.to_string(System.unique_integer([:positive, :monotonic]))

    request =
      Request.new(
        "request-" <> identity,
        String.to_integer(identity),
        revision,
        Enum.concat(messages, [Context.user(content)])
      )

    Process.put({__MODULE__, pid, :active_request}, request)
    Process.put({__MODULE__, :provider_for_request, request.request_id}, pid)
    Native.send_prompt(pid, request)
  end

  defp continue(pid) do
    content =
      "Your previous response was interrupted mid-stream. Please continue from where you left off. Do not repeat what you already said."

    messages = Process.get({__MODULE__, pid, :messages}, [])
    revision = Process.get({__MODULE__, pid, :revision}, 0)
    identity = Integer.to_string(System.unique_integer([:positive, :monotonic]))

    request =
      Request.new(
        "request-" <> identity,
        String.to_integer(identity),
        revision,
        Enum.concat(messages, [Context.user(content)])
      )

    Process.put({__MODULE__, pid, :active_request}, request)
    Process.put({__MODULE__, :provider_for_request, request.request_id}, pid)
    Native.continue(pid, request)
  end

  defp fake_error_client(error_reason) do
    fn _model, _messages, _opts ->
      {:error, error_reason}
    end
  end

  defp start_provider(opts) do
    subscriber = start_provider_subscriber(self())

    defaults = [
      subscriber: subscriber,
      model: "anthropic:claude-sonnet-4-20250514",
      model_selection: ModelSelectionFixture.selection(),
      config: %AgentConfig{},
      project_root: opts[:tmp_dir] || System.tmp_dir!(),
      tools: [],
      skip_api_key_env: true
    ]

    merged = Keyword.merge(defaults, opts)

    merged =
      case Keyword.pop(merged, :thinking_level) do
        {nil, merged} ->
          merged

        {level, merged} ->
          {:ok, selection} =
            MingaAgent.ModelSelection.with_reasoning(
              Keyword.fetch!(merged, :model_selection),
              level
            )

          Keyword.put(merged, :model_selection, selection)
      end

    Native.start_link(merged)
  end

  defp start_provider_subscriber(owner) do
    spawn_link(fn ->
      owner_ref = Process.monitor(owner)
      provider_subscriber_loop(owner, owner_ref)
    end)
  end

  defp provider_subscriber_loop(owner, owner_ref) do
    receive do
      {:agent_provider_event, _request_id, %Event.AgentEnd{outcome: outcome} = event} ->
        send(owner, {:native_test_outcome, outcome})
        send(owner, {:agent_provider_event, event})
        provider_subscriber_loop(owner, owner_ref)

      {:agent_provider_event, _request_id, event} ->
        send(owner, {:agent_provider_event, event})
        provider_subscriber_loop(owner, owner_ref)

      {:agent_provider_event, event} ->
        send(owner, {:agent_provider_event, event})
        provider_subscriber_loop(owner, owner_ref)

      {:"$gen_call", from, {:checkpoint_tool_group, request_id, _messages, _calls}} ->
        GenServer.reply(from, {:ok, "checkpoint-" <> request_id})
        provider_subscriber_loop(owner, owner_ref)

      {:"$gen_call", from,
       {:admit_tool_effect, _request_id, _checkpoint_id, tool_call_id, _name, _args}} ->
        send(owner, {:effect_admitted, tool_call_id})
        GenServer.reply(from, :ok)
        provider_subscriber_loop(owner, owner_ref)

      {:"$gen_call", from,
       {:complete_tool_effect, _request_id, _checkpoint_id, _tool_call_id, _result_message}} ->
        GenServer.reply(from, :ok)
        provider_subscriber_loop(owner, owner_ref)

      {:"$gen_call", from, :dequeue_steering_messages} ->
        GenServer.reply(from, [])
        provider_subscriber_loop(owner, owner_ref)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok
    end
  end

  defp start_effect_registration_manager(owner) do
    spawn_link(fn -> effect_registration_manager_loop(owner, Process.monitor(owner)) end)
  end

  defp effect_registration_manager_loop(owner, owner_ref) do
    receive do
      {:"$gen_call", from, {:register_effect_workers, session_pid, provider_pid, worker_pids}} ->
        send(owner, {:session_effect_workers_registered, session_pid, provider_pid, worker_pids})
        GenServer.reply(from, :ok)
        effect_registration_manager_loop(owner, owner_ref)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok
    end
  end

  defp start_effect_barrier_subscriber(
         owner,
         checkpoint_reply,
         admission_reply,
         terminal_replies \\ [:ok]
       ) do
    spawn_link(fn ->
      effect_barrier_subscriber_loop(
        owner,
        Process.monitor(owner),
        checkpoint_reply,
        admission_reply,
        terminal_replies
      )
    end)
  end

  defp effect_barrier_subscriber_loop(
         owner,
         owner_ref,
         checkpoint_reply,
         admission_reply,
         terminal_replies
       ) do
    receive do
      {:agent_provider_event, _request_id, %Event.AgentEnd{outcome: outcome} = event} ->
        send(owner, {:native_test_outcome, outcome})
        send(owner, {:agent_provider_event, event})

        effect_barrier_subscriber_loop(
          owner,
          owner_ref,
          checkpoint_reply,
          admission_reply,
          terminal_replies
        )

      {:agent_provider_event, _request_id, event} ->
        send(owner, {:agent_provider_event, event})

        effect_barrier_subscriber_loop(
          owner,
          owner_ref,
          checkpoint_reply,
          admission_reply,
          terminal_replies
        )

      {:agent_provider_event, event} ->
        send(owner, {:agent_provider_event, event})

        effect_barrier_subscriber_loop(
          owner,
          owner_ref,
          checkpoint_reply,
          admission_reply,
          terminal_replies
        )

      {:"$gen_call", from, {:checkpoint_tool_group, request_id, messages, calls}} ->
        send(owner, {:checkpoint_attempt, request_id, messages, calls})
        GenServer.reply(from, checkpoint_reply)

        effect_barrier_subscriber_loop(
          owner,
          owner_ref,
          checkpoint_reply,
          admission_reply,
          terminal_replies
        )

      {:"$gen_call", from,
       {:admit_tool_effect, request_id, checkpoint_id, tool_call_id, name, args}} ->
        send(owner, {:admission_attempt, request_id, checkpoint_id, tool_call_id, name, args})
        GenServer.reply(from, admission_reply)

        effect_barrier_subscriber_loop(
          owner,
          owner_ref,
          checkpoint_reply,
          admission_reply,
          terminal_replies
        )

      {:"$gen_call", from,
       {:complete_tool_effect, request_id, checkpoint_id, tool_call_id, result_message}} ->
        send(
          owner,
          {:terminal_persistence_attempt, request_id, checkpoint_id, tool_call_id, result_message}
        )

        [terminal_reply | remaining_replies] = terminal_replies
        GenServer.reply(from, terminal_reply)

        effect_barrier_subscriber_loop(
          owner,
          owner_ref,
          checkpoint_reply,
          admission_reply,
          if(remaining_replies == [], do: [:ok], else: remaining_replies)
        )

      {:"$gen_call", from, :dequeue_steering_messages} ->
        GenServer.reply(from, [])

        effect_barrier_subscriber_loop(
          owner,
          owner_ref,
          checkpoint_reply,
          admission_reply,
          terminal_replies
        )

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok
    end
  end

  defp agent_config(fields) do
    struct!(AgentConfig, fields)
  end

  defp write_project_skill(dir, name, instructions) do
    skill_dir = Path.join([dir, ".minga", "skills", name])
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{name} skill
    ---

    #{instructions}
    """)
  end

  # Wait for events with a helper that collects all events within a timeout.
  # Waits for a full agent run, collecting every event up to and including the
  # terminal AgentEnd (which the Native provider emits on every path: normal
  # finish, turn/cost limit, stream interruption, LLM error, task crash, abort).
  # Uses an overall deadline rather than an inter-event silence gap, so a
  # slow-but-healthy pause between events (e.g. a real tool execution on a
  # loaded CI runner) can never silently truncate the run mid-collection. If
  # AgentEnd never arrives, this fails loudly with the events collected so far
  # instead of returning a partial list that surfaces as a confusing downstream
  # assertion failure.
  @full_run_deadline_ms 10_000

  defp collect_run_events(deadline_ms \\ @full_run_deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    collect_run_events_acc([], deadline, deadline_ms)
  end

  defp collect_run_events_acc(acc, deadline, deadline_ms) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:native_test_outcome, nil} ->
        collect_run_events_acc(acc, deadline, deadline_ms)

      {:native_test_outcome, outcome} ->
        Process.put({__MODULE__, outcome.request_id, :outcome}, outcome)

        case Process.get({__MODULE__, :provider_for_request, outcome.request_id}) do
          nil ->
            :ok

          pid ->
            Process.put({__MODULE__, pid, :messages}, outcome.messages)
            Process.put({__MODULE__, pid, :revision}, outcome.conversation_revision + 1)
        end

        collect_run_events_acc(acc, deadline, deadline_ms)

      {:agent_provider_event, %Event.AgentEnd{} = event} ->
        Enum.reverse([event | acc])

      {:agent_provider_event, event} ->
        collect_run_events_acc([event | acc], deadline, deadline_ms)
    after
      timeout ->
        flunk("""
        collect_run_events/1 timed out after #{deadline_ms}ms without an AgentEnd.
        Collected #{length(acc)} event(s): #{inspect(Enum.reverse(acc))}
        """)
    end
  end

  defp tool_message_text(message) do
    Enum.map_join(message.content, "", & &1.text)
  end

  defp text_content(message) do
    Enum.map_join(message.content, "", &(&1.text || ""))
  end

  defp collect_spawned_processes(parent, count) do
    collect_spawned_processes(parent, count, [])
  end

  defp collect_spawned_processes(_parent, 0, acc), do: Enum.reverse(acc)

  defp collect_spawned_processes(parent, count, acc) do
    receive do
      {:trace, ^parent, :spawn, pid, _mfa} ->
        collect_spawned_processes(parent, count - 1, [pid | acc])
    after
      1_000 ->
        flunk("expected #{count} more spawned process(es) from #{inspect(parent)}")
    end
  end

  # ── Lifecycle tests ─────────────────────────────────────────────────────────

  describe "init, context, and thinking level" do
    test "get_state exposes initial model, project context, skills, and AGENTS instructions", %{
      tmp_dir: dir
    } do
      write_project_skill(dir, "plan", "PLAN SKILL 1419")
      File.write!(Path.join(dir, "AGENTS.md"), "PROJECT RULE 1419")

      {:ok, pid} =
        start_provider(tmp_dir: dir, thinking_level: "high", active_skill_names: ["plan"])

      assert {:ok, session_state} = Native.get_state(pid)
      assert session_state.model.provider == "openai"
      assert String.starts_with?(session_state.model.id, "ms2_")
      assert session_state.is_streaming == false
      assert session_state.thinking_level == "high"
      assert session_state.active_skill_names == ["plan"]
      assert session_state.project_root == dir
      assert session_state.system_prompt =~ "PLAN SKILL 1419"
      assert session_state.system_prompt =~ "PROJECT RULE 1419"
    end

    test "falls back to the process working directory when no project is active" do
      {:ok, pid} = start_provider(project_root: nil)

      assert {:ok, session_state} = Native.get_state(pid)
      assert session_state.project_root == File.cwd!()
      assert session_state.system_prompt =~ "Project root: #{File.cwd!()}"
    end

    test "default Git tools are advertised only inside a repository", %{tmp_dir: dir} do
      on_exit(fn -> GitStub.clear(dir) end)
      parent = self()

      tool_names_for = fn tools ->
        ref = make_ref()

        client = fn _model, _messages, opts ->
          send(parent, {ref, Enum.map(opts[:tools], & &1.name)})

          build_stream_response([
            ReqLLM.StreamChunk.text("done"),
            ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
          ])
        end

        {:ok, pid} =
          start_provider(project_root: dir, tools: tools, llm_client: client)

        assert :ok = send_prompt(pid, "Inspect the project")
        assert_receive {^ref, names}, 5_000
        _events = collect_run_events()
        names
      end

      refute "git_status" in tool_names_for.(nil)

      GitStub.set_root(dir, dir)
      assert "git_status" in tool_names_for.(nil)

      git_status = Enum.find(Tools.specs(), &(&1.name == "git_status"))
      GitStub.clear(dir)
      assert "git_status" in tool_names_for.([git_status])
    end

    test "find executes from the fallback working directory when no project is active" do
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count == 0 do
            [
              ReqLLM.StreamChunk.tool_call("find", %{"pattern" => "*.ex", "path" => "."}, %{
                id: "tc_find_without_project",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          project_root: nil,
          llm_client: client,
          tools: nil,
          process_backend: RecordingProcessBackend
        )

      assert :ok = send_prompt(pid, "Find Elixir files")
      events = collect_run_events()

      assert %Event.ToolEnd{is_error: false, result: result} =
               Enum.find(events, &match?(%Event.ToolEnd{name: "find"}, &1))

      assert result =~ "find pattern=*.ex"
      assert result =~ "path=#{File.cwd!()}"
    end

    test "an approved shell command completes from the working directory without an active project" do
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count == 0 do
            [
              ReqLLM.StreamChunk.tool_call("shell", %{"command" => "pwd"}, %{
                id: "tc_shell_without_project",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          project_root: nil,
          llm_client: client,
          tools: nil,
          process_backend: RecordingProcessBackend,
          config: agent_config(tool_approval: :destructive, destructive_tools: ["shell"])
        )

      assert :ok = send_prompt(pid, "Print the working directory")

      assert_receive {:agent_provider_event,
                      %Event.ToolApproval{
                        tool_call_id: "tc_shell_without_project",
                        reply_to: reply_to
                      }},
                     5_000

      send(reply_to, {:tool_approval_response, "tc_shell_without_project", :approve})
      events = collect_run_events()

      assert %Event.ToolEnd{is_error: false, result: result} =
               Enum.find(events, &match?(%Event.ToolEnd{name: "shell"}, &1))

      assert result =~ "shell command=pwd"
      assert result =~ "cwd=#{File.cwd!()}"
    end

    test "system prompt keeps cacheable environment prefix stable within a session", %{
      tmp_dir: dir
    } do
      {:ok, pid} = start_provider(tmp_dir: dir)

      assert {:ok, session_state} = Native.get_state(pid)
      assert session_state.system_prompt =~ "Project root: #{dir}"

      assert session_state.system_prompt =~
               "list_directory: List entries at a known-small path. Bounded and ignores generated trees."

      assert session_state.system_prompt =~
               "Do not use shell to recursively list or search files when find or grep can answer the question."

      refute session_state.system_prompt =~ "Current time:"
    end

    test "provider compaction honors configured threshold", %{tmp_dir: dir} do
      parent = self()

      client = fn _model, messages, _opts ->
        if Enum.any?(messages, &(text_content(&1) =~ "Summarize this conversation")) do
          send(parent, :summary_called)
          build_stream_response([ReqLLM.StreamChunk.text("summary")])
        else
          send(parent, :agent_called)
          build_stream_response([ReqLLM.StreamChunk.text("answer")])
        end
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          config: agent_config(compaction_threshold: 0.0, compaction_keep_recent: 1)
        )

      Process.put(
        {__MODULE__, pid, :messages},
        [
          Context.user(String.duplicate("user ", 200)),
          Context.assistant(String.duplicate("assistant ", 200))
        ]
      )

      messages = Process.get({__MODULE__, pid, :messages})
      assert {:ok, compacted, _summary} = Native.compact(pid, messages, [])
      assert compacted != messages
      assert_receive :summary_called, 1_000
    end

    test "thinking level accepts known values, rejects unknown values, and cycles in order", %{
      tmp_dir: dir
    } do
      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          model_selection:
            ModelSelectionFixture.selection(
              reasoning: %{effort: "off", options: ["off", "low", "medium", "high"]}
            )
        )

      for level <- ["low", "medium", "high", "off"] do
        assert :ok = Native.set_thinking_level(pid, level)
      end

      assert {:error, _reason} = Native.set_thinking_level(pid, "turbo")
      assert {:ok, %{thinking_level: "off"}} = Native.get_state(pid)

      assert {:ok, %{"level" => "low"}} = Native.cycle_thinking_level(pid)
      assert {:ok, %{"level" => "medium"}} = Native.cycle_thinking_level(pid)
      assert {:ok, %{"level" => "high"}} = Native.cycle_thinking_level(pid)
      assert {:ok, %{"level" => "off"}} = Native.cycle_thinking_level(pid)
    end

    test "rebuilds built-in tool closures after fork store down so stale pids stop leaking", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "lib/tool_rebuild.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "original\n")

      {:ok, buffer} = start_supervised({BufferProcess, content: "original\n", file_path: path})
      {:ok, pid} = start_provider(tmp_dir: dir, tools: nil)

      fork_store = Native.fork_store(pid)
      assert is_pid(fork_store)
      write_tool = pid |> Native.tools() |> Enum.find(&(&1.name == "write_file"))

      assert {:ok, result} =
               write_tool.callback.(%{"path" => "lib/tool_rebuild.ex", "content" => "forked\n"})

      assert result =~ "via fork"
      assert File.read!(path) == "original\n"
      assert Minga.Buffer.content(buffer) == "original\n"

      ref = Process.monitor(fork_store)
      Process.exit(fork_store, :kill)
      assert_receive {:DOWN, ^ref, :process, ^fork_store, _reason}

      assert Native.fork_store(pid) == nil
      rebuilt_write_tool = pid |> Native.tools() |> Enum.find(&(&1.name == "write_file"))

      assert {:ok, result} =
               rebuilt_write_tool.callback.(%{
                 "path" => "lib/tool_rebuild.ex",
                 "content" => "direct\n"
               })

      assert result =~ "wrote"
      assert File.read!(path) == "original\n"
      assert Minga.Buffer.content(buffer) == "direct\n"
    end

    test "rebuilds only custom tool declarations after fork store down", %{tmp_dir: dir} do
      test_pid = self()

      spec =
        Spec.new!(
          source: :config,
          name: "custom_restart",
          description: "Reports the bound fork store",
          parameter_schema: %{},
          build: fn context ->
            fn _args ->
              send(test_pid, {:bound_fork_store, context.router_context.fork_store})
              {:ok, "reported"}
            end
          end
        )

      {:ok, pid} = start_provider(tmp_dir: dir, tools: [spec])
      fork_store = Native.fork_store(pid)
      assert is_pid(fork_store)

      custom_tool = pid |> Native.tools() |> Enum.find(&(&1.name == "custom_restart"))
      assert {:ok, "reported"} = custom_tool.callback.(%{})
      assert_receive {:bound_fork_store, ^fork_store}

      ref = Process.monitor(fork_store)
      Process.exit(fork_store, :kill)
      assert_receive {:DOWN, ^ref, :process, ^fork_store, _reason}
      assert Native.fork_store(pid) == nil

      rebuilt_tools = Native.tools(pid)

      assert Enum.map(rebuilt_tools, & &1.name) == [
               "custom_restart",
               "todo_write",
               "todo_read",
               "notebook_write",
               "notebook_read"
             ]

      rebuilt_custom_tool = Enum.find(rebuilt_tools, &(&1.name == "custom_restart"))
      assert {:ok, "reported"} = rebuilt_custom_tool.callback.(%{})
      assert_receive {:bound_fork_store, nil}
    end

    test "project_view-backed tools reuse the workspace-owned draft machinery and survive provider exit",
         %{tmp_dir: dir} do
      path = Path.join(dir, "lib/view_draft.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "original\n")

      {:ok, buffer} = start_supervised({BufferProcess, content: "original\n", file_path: path})
      {:ok, view} = ProjectView.overlay(dir)
      {:ok, pid} = start_provider(tmp_dir: dir, project_view: view, tools: nil)

      assert Native.project_view(pid) == view
      assert Native.fork_store(pid) == nil
      assert Native.changeset(pid) == nil

      write_tool = pid |> Native.tools() |> Enum.find(&(&1.name == "write_file"))

      assert {:ok, result} =
               write_tool.callback.(%{"path" => "lib/view_draft.ex", "content" => "draft\n"})

      assert result =~ "via ProjectView"
      assert File.read!(path) == "original\n"
      assert {:ok, "draft\n"} = ProjectView.read_file(view, "lib/view_draft.ex")

      assert {:ok, diff} = ProjectView.diff(view)
      assert %{path: "lib/view_draft.ex", kind: :modified} in diff

      GenServer.stop(pid, :normal)
      assert {:ok, "draft\n"} = ProjectView.read_file(view, "lib/view_draft.ex")
      assert {:ok, diff_after} = ProjectView.diff(view)
      assert %{path: "lib/view_draft.ex", kind: :modified} in diff_after
      assert Minga.Buffer.content(buffer) == "original\n"
    end

    test "send_prompt passes semantic reasoning_effort for each provider", %{tmp_dir: dir} do
      cases = [
        {"anthropic:claude-sonnet-4-20250514", "high", :high},
        {"openai:o4-mini", "medium", :medium},
        {"deepseek:deepseek-reasoner", "low", :low},
        {"openai:o3-mini", "off", nil},
        {"openai_codex:gpt-5.5", "high", :high}
      ]

      Enum.each(cases, fn {model, thinking_level, expected_effort} ->
        test_pid = self()
        ref = make_ref()

        client = fn captured_model, _messages, opts ->
          send(test_pid, {ref, captured_model, opts})
          build_stream_response([ReqLLM.StreamChunk.text("ok")])
        end

        model_id = model |> String.split(":", parts: 2) |> List.last()

        {:ok, pid} =
          start_provider(
            tmp_dir: dir,
            model: model,
            model_selection: ModelSelectionFixture.selection(model_id: model_id),
            thinking_level: thinking_level,
            llm_client: client
          )

        assert :ok = send_prompt(pid, "test")
        assert_receive {^ref, %LLMDB.Model{provider_model_id: ^model_id}, opts}, 2_000

        if expected_effort do
          assert Keyword.get(opts, :reasoning_effort) == expected_effort
        else
          refute Keyword.has_key?(opts, :reasoning_effort)
        end

        provider_options = Keyword.get(opts, :provider_options, [])
        refute Keyword.has_key?(provider_options, :additional_model_request_fields)

        collect_run_events()
      end)
    end
  end

  describe "model changes" do
    test "set_model updates state, preserves thinking level, and keeps conversation context", %{
      tmp_dir: dir
    } do
      test_pid = self()
      calls = :counters.new(1, [:atomics])
      messages_ref = make_ref()

      client = fn model, messages, _opts ->
        count = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)
        send(test_pid, {messages_ref, count, model, messages})

        build_stream_response([
          ReqLLM.StreamChunk.text("Response #{count}"),
          ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
        ])
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, thinking_level: "medium")

      :ok = send_prompt(pid, "Hello")
      collect_run_events()

      switched_selection =
        ModelSelectionFixture.selection(
          model_id: "o4-mini",
          display_name: "o4-mini",
          reasoning: %{effort: "medium", options: ["off", "medium"]}
        )

      assert :ok = Native.set_model(pid, switched_selection)
      assert {:ok, state} = Native.get_state(pid)
      assert state.model.id == MingaAgent.ModelSelection.id(switched_selection)
      assert state.model.name == "o4-mini"
      assert state.thinking_level == "medium"

      :ok = send_prompt(pid, "Follow up")
      collect_run_events()

      assert_received {^messages_ref, 1, %LLMDB.Model{provider_model_id: "o4-mini"}, messages}

      assert Enum.map(messages, &{&1.role, text_content(&1)}) == [
               {:user, "Hello"},
               {:assistant, "Response 0"},
               {:user, "Follow up"}
             ]
    end
  end

  describe "new_session" do
    test "resets conversation context", %{tmp_dir: dir} do
      {:ok, pid} = start_provider(tmp_dir: dir)

      assert :ok = Native.new_session(pid)
      assert {:ok, state} = Native.get_state(pid)
      assert state.is_streaming == false
    end
  end

  # ── Streaming tests ─────────────────────────────────────────────────────────

  describe "send_prompt streaming" do
    test "rejects a turn when the exact route does not explicitly support tools", %{
      tmp_dir: dir
    } do
      selection =
        ModelSelectionFixture.selection(
          display_name: "Text Only",
          capabilities: %{tools: :unknown, images: false, streaming: true}
        )

      test_pid = self()

      client = fn _model, _messages, _opts ->
        send(test_pid, :unsupported_tool_request_started)
        {:error, :unexpected_request}
      end

      {:ok, pid} =
        start_provider(tmp_dir: dir, model_selection: selection, llm_client: client)

      assert {:error, message} = send_prompt(pid, "Inspect the project")
      assert message =~ "does not explicitly support tools"
      assert message =~ "Choose a tool-capable route"
      refute_received :unsupported_tool_request_started
      assert {:ok, %{is_streaming: false}} = Native.get_state(pid)
    end

    test "rejects image history when the exact route does not support images", %{tmp_dir: dir} do
      selection =
        ModelSelectionFixture.selection(
          display_name: "No Images",
          capabilities: %{tools: true, images: false, streaming: true}
        )

      {:ok, pid} = start_provider(tmp_dir: dir, model_selection: selection)
      image = ContentPart.image(<<0, 1, 2>>, "image/png")

      assert {:error, message} = send_prompt(pid, [image])
      assert message =~ "does not explicitly support image input"
      assert message =~ "Choose an image-capable route"
      assert {:ok, %{is_streaming: false}} = Native.get_state(pid)
    end

    test "emits start, text, thinking, and end events", %{tmp_dir: dir} do
      chunks = [
        ReqLLM.StreamChunk.thinking("Let me think..."),
        ReqLLM.StreamChunk.text("Hello "),
        ReqLLM.StreamChunk.text("world!"),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ]

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: fake_llm_client(chunks, %{input_tokens: 10, output_tokens: 5})
        )

      assert :ok = send_prompt(pid, "Hi")

      events = collect_run_events()
      assert %Event.AgentStart{} = Enum.at(events, 0)

      assert [%Event.ThinkingDelta{delta: "Let me think..."}] =
               Enum.filter(events, &match?(%Event.ThinkingDelta{}, &1))

      assert Enum.map(Enum.filter(events, &match?(%Event.TextDelta{}, &1)), & &1.delta) == [
               "Hello ",
               "world!"
             ]

      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    end
  end

  describe "send_prompt with tool calls" do
    @tag :tmp_dir
    test "Session owner death terminates an admitted effect worker", %{tmp_dir: dir} do
      test_pid = self()

      tool =
        ReqLLM.Tool.new!(
          name: "owner_lifecycle_effect",
          description: "Waits until its Session owner is gone",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:owner_effect_started, self()})

            receive do
              :allow_effect_completion ->
                send(test_pid, :owner_effect_completed)
                {:ok, "completed"}
            end
          end
        )

      client = fn _model, _messages, _opts ->
        build_stream_response([
          ReqLLM.StreamChunk.tool_call("owner_lifecycle_effect", %{}, %{
            id: "tc_owner_lifecycle",
            index: 0
          }),
          ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
        ])
      end

      subscriber =
        start_effect_barrier_subscriber(
          self(),
          {:ok, "owner-checkpoint"},
          :ok
        )

      Process.unlink(subscriber)

      manager = start_effect_registration_manager(self())
      Process.unlink(manager)

      {:ok, provider} =
        start_provider(
          tmp_dir: dir,
          subscriber: subscriber,
          llm_client: client,
          tools: [tool],
          session_manager: manager
        )

      Process.unlink(provider)
      provider_ref = Process.monitor(provider)
      subscriber_ref = Process.monitor(subscriber)

      assert :ok = send_prompt(provider, "run one effect")
      assert_receive {:admission_attempt, _, _, "tc_owner_lifecycle", _, _}, 1_000
      assert_receive {:owner_effect_started, worker}, 1_000
      worker_ref = Process.monitor(worker)

      assert_receive {
                       :session_effect_workers_registered,
                       ^subscriber,
                       ^provider,
                       [^worker]
                     },
                     1_000

      Process.exit(subscriber, :kill)

      assert_receive {:DOWN, ^subscriber_ref, :process, ^subscriber, :killed}, 1_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000
      assert_receive {:DOWN, ^provider_ref, :process, ^provider, _reason}, 1_000
      refute_receive :owner_effect_completed, 50
    end

    test "checkpoint persistence failure prevents admission and tool execution", %{tmp_dir: dir} do
      test_pid = self()

      tool =
        ReqLLM.Tool.new!(
          name: "checkpoint_barrier_effect",
          description: "Must not execute without a durable provider checkpoint",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, :checkpoint_barrier_effect_executed)
            {:ok, "executed"}
          end
        )

      client = fn _model, _messages, _opts ->
        build_stream_response([
          ReqLLM.StreamChunk.tool_call("checkpoint_barrier_effect", %{}, %{
            id: "tc_checkpoint_failure",
            index: 0
          }),
          ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
        ])
      end

      subscriber =
        start_effect_barrier_subscriber(
          self(),
          {:error, {:tool_checkpoint_failed, :disk_full}},
          :ok
        )

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          subscriber: subscriber,
          llm_client: client,
          tools: [tool]
        )

      assert :ok = send_prompt(pid, "run it")
      events = collect_run_events()
      refute Enum.any?(events, &match?(%Event.ToolStart{}, &1))

      assert_receive {:checkpoint_attempt, _request_id, messages, [call]}, 1_000
      [assistant_message | _rest] = Enum.reverse(messages)
      assert assistant_message.role == :assistant
      assert Enum.map(assistant_message.tool_calls, & &1.id) == ["tc_checkpoint_failure"]
      assert call.tool_call_id == "tc_checkpoint_failure"
      refute_receive {:admission_attempt, _, _, _, _, _}, 100
      refute_receive :checkpoint_barrier_effect_executed, 100
    end

    test "ambiguous admission failure aborts before execution and model continuation", %{
      tmp_dir: dir
    } do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      tool =
        ReqLLM.Tool.new!(
          name: "admission_barrier_effect",
          description: "Must not execute without durable single-attempt admission",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, :admission_barrier_effect_executed)
            {:ok, "executed"}
          end
        )

      client = fn _model, _messages, _opts ->
        :counters.add(call_count, 1, 1)

        build_stream_response([
          ReqLLM.StreamChunk.tool_call("admission_barrier_effect", %{}, %{
            id: "tc_admission_failure",
            index: 0
          }),
          ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
        ])
      end

      subscriber =
        start_effect_barrier_subscriber(
          self(),
          {:ok, "checkpoint-admission-failure"},
          {:error, {:effect_admission_failed, :journal_unavailable}}
        )

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          subscriber: subscriber,
          llm_client: client,
          tools: [tool]
        )

      assert :ok = send_prompt(pid, "run it")
      events = collect_run_events()

      assert_receive {:admission_attempt, _request_id, "checkpoint-admission-failure",
                      "tc_admission_failure", "admission_barrier_effect", %{}},
                     1_000

      refute_received {:terminal_persistence_attempt, _, _, _, _}
      assert Enum.any?(events, &match?(%Event.Error{}, &1))
      assert Enum.any?(events, &match?(%Event.AgentEnd{outcome: nil}, &1))
      assert :counters.get(call_count, 1) == 1
      refute_received :admission_barrier_effect_executed
    end

    test "terminal persistence retries never invoke an admitted effect twice", %{tmp_dir: dir} do
      invocation_count = :counters.new(1, [:atomics])
      model_call_count = :counters.new(1, [:atomics])

      tool =
        ReqLLM.Tool.new!(
          name: "outcome_retry_effect",
          description: "Executes once while terminal persistence retries",
          parameter_schema: [],
          callback: fn _args ->
            :counters.add(invocation_count, 1, 1)
            {:ok, "executed once"}
          end
        )

      client = fn _model, _messages, _opts ->
        count = :counters.get(model_call_count, 1)
        :counters.add(model_call_count, 1, 1)

        if count == 0 do
          build_stream_response([
            ReqLLM.StreamChunk.tool_call("outcome_retry_effect", %{}, %{
              id: "tc_outcome_retry",
              index: 0
            }),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ])
        else
          build_stream_response([
            ReqLLM.StreamChunk.text("Recovered the recorded result."),
            ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
          ])
        end
      end

      subscriber =
        start_effect_barrier_subscriber(
          self(),
          {:ok, "checkpoint-outcome-retry"},
          :ok,
          [
            {:error, {:tool_outcome_persistence_failed, :disk_busy}},
            {:error, {:tool_outcome_persistence_failed, :disk_busy}},
            :ok
          ]
        )

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          subscriber: subscriber,
          llm_client: client,
          tools: [tool]
        )

      assert :ok = send_prompt(pid, "run it")
      _events = collect_run_events()

      assert_receive {:terminal_persistence_attempt, _, "checkpoint-outcome-retry",
                      "tc_outcome_retry", _},
                     1_000

      assert_receive {:terminal_persistence_attempt, _, "checkpoint-outcome-retry",
                      "tc_outcome_retry", _},
                     1_000

      assert_receive {:terminal_persistence_attempt, _, "checkpoint-outcome-retry",
                      "tc_outcome_retry", _},
                     1_000

      assert :counters.get(invocation_count, 1) == 1
    end

    test "executes tools and emits tool events", %{tmp_dir: dir} do
      # Write a file so the read_file tool can find it
      File.write!(Path.join(dir, "test.txt"), "file contents")

      # First call returns a tool_call, second call returns final answer
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count == 0 do
            # First call: tool use
            [
              ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                id: "tc_1",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            # Second call: final answer
            [
              ReqLLM.StreamChunk.text("The file says: file contents"),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks)
      end

      tools = Tools.all(project_root: dir)
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, tools: tools)

      assert :ok = send_prompt(pid, "Read test.txt")

      events = collect_run_events()

      # Should have tool start and tool end events
      tool_starts = Enum.filter(events, &match?(%Event.ToolStart{}, &1))
      assert [first_start | _] = tool_starts
      assert first_start.name == "read_file"

      tool_ends = Enum.filter(events, &match?(%Event.ToolEnd{}, &1))
      assert [first_end | _] = tool_ends
      assert first_end.result =~ "file contents"
      assert first_end.is_error == false

      # Should eventually get a text response and AgentEnd
      assert Enum.any?(events, &match?(%Event.TextDelta{}, &1))
      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "replays the complete assistant response before appending grouped tool results", %{
      tmp_dir: dir
    } do
      File.write!(Path.join(dir, "test.txt"), "file contents")
      parent = self()
      call_count = :counters.new(1, [:atomics])

      reasoning =
        ReqLLM.Message.ReasoningDetails.from_openai_compatible(
          %{"text" => "checking the file", "signature" => "opaque-signature"},
          :openrouter,
          0
        )

      client = fn _model, messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case count do
          0 ->
            build_stream_response(
              [
                ReqLLM.StreamChunk.text("I will inspect it."),
                ReqLLM.StreamChunk.thinking("checking the file"),
                ReqLLM.StreamChunk.text(" Then I will verify the results."),
                ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                  id: "tc_first",
                  index: 0
                }),
                ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                  id: "tc_second",
                  index: 1
                }),
                ReqLLM.StreamChunk.meta(%{
                  finish_reason: :tool_use,
                  reasoning_details: [reasoning]
                })
              ],
              %{},
              %{response_id: "resp_native_1"}
            )

          1 ->
            send(parent, {:continuation_messages, messages})

            build_stream_response([
              ReqLLM.StreamChunk.text("The file contents are confirmed."),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ])
        end
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: Tools.all(project_root: dir)
        )

      assert :ok = send_prompt(pid, "Read test.txt twice")
      _events = collect_run_events()

      assert_received {:continuation_messages, messages}

      assistant_message =
        Enum.find(messages, &(&1.role == :assistant and is_list(&1.tool_calls)))

      assert Enum.map(assistant_message.content, & &1.type) == [:text, :thinking, :text]

      assert Enum.map(assistant_message.content, & &1.text) == [
               "I will inspect it.",
               "checking the file",
               " Then I will verify the results."
             ]

      assert assistant_message.reasoning_details == [reasoning]
      assert assistant_message.metadata.response_id == "resp_native_1"
      assert Enum.map(assistant_message.tool_calls, & &1.id) == ["tc_first", "tc_second"]

      tool_results =
        Enum.filter(
          messages,
          &(&1.role == :tool and &1.tool_call_id in ["tc_first", "tc_second"])
        )

      assert Enum.map(tool_results, & &1.tool_call_id) == ["tc_first", "tc_second"]
      assert Enum.all?(tool_results, &(text_content(&1) == "file contents"))
    end

    test "executes the supplied custom spec with refreshed project context", %{tmp_dir: dir} do
      root = Path.join(dir, "root")
      first_working_dir = Path.join(dir, "first")
      second_working_dir = Path.join(dir, "second")
      File.mkdir_p!(root)

      {:ok, first_view} =
        RecordingBackend.create(root,
          parent: self(),
          working_dir: first_working_dir,
          workspace_id: 1
        )

      {:ok, second_view} =
        RecordingBackend.create(root,
          parent: self(),
          working_dir: second_working_dir,
          workspace_id: 2
        )

      spec =
        Spec.new!(
          source: :config,
          name: "custom_context",
          description: "Reports the bound project context",
          parameter_schema: %{},
          build: fn context ->
            fn _args -> {:ok, ProjectView.working_dir(context.router_context.project_view)} end
          end
        )

      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count == 0 do
            [
              ReqLLM.StreamChunk.tool_call("custom_context", %{}, %{
                id: "tc_custom_context",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: root,
          project_view: first_view,
          llm_client: client,
          tools: [spec],
          config: agent_config(tool_approval: :none)
        )

      assert :ok = Native.refresh_project_view(pid, second_view)
      assert :ok = send_prompt(pid, "Report context")

      events = collect_run_events()

      assert Enum.any?(events, fn
               %Event.ToolEnd{name: "custom_context", result: result, is_error: false} ->
                 result == second_working_dir

               _event ->
                 false
             end)
    end

    test "executes independent tool calls concurrently and appends results in call order", %{
      tmp_dir: dir
    } do
      test_pid = self()
      release_ref = make_ref()
      messages_ref = make_ref()
      call_count = :counters.new(1, [:atomics])

      slow_tool =
        ReqLLM.Tool.new!(
          name: "slow_tool",
          description: "Blocks until the test releases it",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:tool_started, "slow_tool", self()})

            receive do
              {^release_ref, :release} -> {:ok, "slow result"}
            after
              2_000 -> {:error, "slow tool timed out"}
            end
          end
        )

      failing_tool =
        ReqLLM.Tool.new!(
          name: "failing_tool",
          description: "Fails immediately",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:tool_started, "failing_tool", self()})
            {:error, "boom"}
          end
        )

      client = fn _model, messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call("slow_tool", %{}, %{id: "tc_slow", index: 0}),
                ReqLLM.StreamChunk.tool_call("failing_tool", %{}, %{id: "tc_fail", index: 1}),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              send(test_pid, {messages_ref, messages})
              [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(tmp_dir: dir, llm_client: client, tools: [slow_tool, failing_tool])

      assert :ok = send_prompt(pid, "Run both tools")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000
      assert_receive {:tool_started, "slow_tool", slow_pid}, 2_000
      assert_receive {:tool_started, "failing_tool", _failing_pid}, 2_000

      send(slow_pid, {release_ref, :release})
      events = collect_run_events()

      assert Enum.any?(events, &match?(%Event.ToolEnd{name: "slow_tool", is_error: false}, &1))
      assert Enum.any?(events, &match?(%Event.ToolEnd{name: "failing_tool", is_error: true}, &1))

      assert_received {^messages_ref, messages}
      tool_messages = Enum.filter(messages, fn message -> message.role == :tool end)
      assert Enum.map(tool_messages, & &1.tool_call_id) == ["tc_slow", "tc_fail"]
      assert Enum.map(tool_messages, &tool_message_text/1) == ["slow result", "boom"]
      assert Enum.map(tool_messages, & &1.metadata[:is_error]) == [nil, true]
    end

    test "abnormal concurrent tool exit stops model continuation with an unknown effect", %{
      tmp_dir: dir
    } do
      test_pid = self()
      release_ref = make_ref()
      messages_ref = make_ref()
      call_count = :counters.new(1, [:atomics])

      crashing_tool =
        ReqLLM.Tool.new!(
          name: "crashing_tool",
          description: "Exits abnormally",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:tool_started, "crashing_tool"})
            Process.exit(self(), :kill)
          end
        )

      sibling_tool =
        ReqLLM.Tool.new!(
          name: "sibling_tool",
          description: "Completes after the crashing sibling exits",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:tool_started, "sibling_tool", self()})

            receive do
              {^release_ref, :release} -> {:ok, "sibling result"}
            after
              1_000 -> {:error, "sibling tool timed out"}
            end
          end
        )

      client = fn _model, messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call("crashing_tool", %{}, %{id: "tc_crash", index: 0}),
                ReqLLM.StreamChunk.tool_call("sibling_tool", %{}, %{id: "tc_sibling", index: 1}),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              send(test_pid, {messages_ref, messages})
              [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(tmp_dir: dir, llm_client: client, tools: [crashing_tool, sibling_tool])

      assert :ok = send_prompt(pid, "Run both tools")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000
      assert_receive {:tool_started, "crashing_tool"}, 1_000
      assert_receive {:tool_started, "sibling_tool", sibling_pid}, 1_000

      send(sibling_pid, {release_ref, :release})
      events = collect_run_events()

      refute Enum.any?(events, &match?(%Event.ToolEnd{name: "crashing_tool"}, &1))
      assert Enum.any?(events, &match?(%Event.ToolEnd{name: "sibling_tool", is_error: false}, &1))
      assert Enum.any?(events, &match?(%Event.AgentEnd{outcome: nil}, &1))
      assert Enum.any?(events, &match?(%Event.Error{}, &1))
      assert :counters.get(call_count, 1) == 1
      refute_received {^messages_ref, _messages}
    end

    test "concurrent tool update events keep streaming while sibling tools run", %{tmp_dir: dir} do
      test_pid = self()
      release_ref = make_ref()
      messages_ref = make_ref()
      tool_event_ref = make_ref()
      provider_holder = start_supervised!({Agent, fn -> nil end})
      call_count = :counters.new(1, [:atomics])

      # The real shell tool spawns an OS process, which is unsafe in this async provider test.
      # This custom tool covers the same provider event path by emitting ToolUpdate from a
      # concurrent tool process without starting a shell.
      streaming_tool =
        ReqLLM.Tool.new!(
          name: "streaming_tool",
          description: "Emits ToolUpdate events without spawning an OS shell",
          parameter_schema: [],
          callback: fn _args ->
            provider_pid = Agent.get(provider_holder, & &1)
            send(test_pid, {:streaming_tool_waiting, self()})

            receive do
              {^tool_event_ref, request_id} ->
                send(
                  provider_pid,
                  {:agent_event, request_id,
                   %Event.ToolUpdate{
                     tool_call_id: "tc_stream",
                     name: "shell",
                     partial_result: "stream chunk\n"
                   }}
                )

                {:ok, "stream result"}
            after
              1_000 -> {:error, "stream update synchronization timed out"}
            end
          end
        )

      sibling_tool =
        ReqLLM.Tool.new!(
          name: "stream_sibling_tool",
          description: "Completes after the update has streamed",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:tool_started, "stream_sibling_tool", self()})

            receive do
              {^release_ref, :release} -> {:ok, "sibling result"}
            after
              1_000 -> {:error, "sibling tool timed out"}
            end
          end
        )

      client = fn _model, messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call("streaming_tool", %{}, %{id: "tc_stream", index: 0}),
                ReqLLM.StreamChunk.tool_call("stream_sibling_tool", %{}, %{
                  id: "tc_stream_sibling",
                  index: 1
                }),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              send(test_pid, {messages_ref, messages})
              [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(tmp_dir: dir, llm_client: client, tools: [streaming_tool, sibling_tool])

      Agent.update(provider_holder, fn _old_provider -> pid end)

      assert :ok = send_prompt(pid, "Run both tools")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000
      request = Process.get({__MODULE__, pid, :active_request})
      assert_receive {:streaming_tool_waiting, streaming_tool_pid}, 1_000
      send(streaming_tool_pid, {tool_event_ref, request.request_id})

      assert_receive {:agent_provider_event,
                      %Event.ToolUpdate{
                        tool_call_id: "tc_stream",
                        name: "shell",
                        partial_result: "stream chunk\n"
                      }},
                     1_000

      assert_receive {:tool_started, "stream_sibling_tool", sibling_pid}, 1_000
      send(sibling_pid, {release_ref, :release})
      events = collect_run_events()

      assert Enum.any?(
               events,
               &match?(%Event.ToolEnd{name: "streaming_tool", is_error: false}, &1)
             )

      assert Enum.any?(
               events,
               &match?(%Event.ToolEnd{name: "stream_sibling_tool", is_error: false}, &1)
             )

      assert_received {^messages_ref, messages}
      tool_messages = Enum.filter(messages, fn message -> message.role == :tool end)
      assert Enum.map(tool_messages, & &1.tool_call_id) == ["tc_stream", "tc_stream_sibling"]
    end

    test "registration failure cleans up unstarted concurrent tool workers", %{tmp_dir: dir} do
      previous_trap = Process.flag(:trap_exit, true)

      try do
        test_pid = self()
        release_ref = make_ref()
        marker_one = Path.join(dir, "registration-worker-one-ran.txt")
        marker_two = Path.join(dir, "registration-worker-two-ran.txt")

        tool_one =
          ReqLLM.Tool.new!(
            name: "registration_cleanup_one",
            description: "Should never run after registration failure",
            parameter_schema: [],
            callback: fn _args ->
              File.write!(marker_one, "ran")
              send(test_pid, :registration_cleanup_one_ran)
              {:ok, "ran one"}
            end
          )

        tool_two =
          ReqLLM.Tool.new!(
            name: "registration_cleanup_two",
            description: "Should never run after registration failure",
            parameter_schema: [],
            callback: fn _args ->
              File.write!(marker_two, "ran")
              send(test_pid, :registration_cleanup_two_ran)
              {:ok, "ran two"}
            end
          )

        response =
          build_stream_response([
            ReqLLM.StreamChunk.tool_call("registration_cleanup_one", %{}, %{
              id: "tc_registration_one",
              index: 0
            }),
            ReqLLM.StreamChunk.tool_call("registration_cleanup_two", %{}, %{
              id: "tc_registration_two",
              index: 1
            }),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ])

        client = fn _model, _messages, _opts ->
          send(test_pid, {:registration_cleanup_client_waiting, release_ref})

          receive do
            {^release_ref, :release} -> response
          end
        end

        {:ok, pid} =
          start_provider(tmp_dir: dir, llm_client: client, tools: [tool_one, tool_two])

        assert :ok = send_prompt(pid, "Run both tools")
        assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000
        assert_receive {:registration_cleanup_client_waiting, ^release_ref}, 1_000

        %{task: %Task{pid: task_pid}} = :sys.get_state(pid)
        :erlang.trace(task_pid, true, [:procs])
        :sys.suspend(pid)

        send(task_pid, {release_ref, :release})
        worker_pids = collect_spawned_processes(task_pid, 2)
        :erlang.trace(task_pid, false, [:procs])
        worker_refs = Enum.map(worker_pids, &Process.monitor/1)

        for {worker_ref, worker_pid} <- Enum.zip(worker_refs, worker_pids) do
          assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 7_000
        end

        if Process.alive?(pid) do
          :sys.resume(pid)

          try do
            Native.get_state(pid)
          catch
            :exit, _ -> :ok
          end
        end

        refute_receive :registration_cleanup_one_ran, 50
        refute_receive :registration_cleanup_two_ran, 50
        refute File.exists?(marker_one)
        refute File.exists?(marker_two)
      after
        Process.flag(:trap_exit, previous_trap)
      end
    end

    test "empty destructive tool configuration allows formerly destructive builtins", %{
      tmp_dir: dir
    } do
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call(
                  "write_file",
                  %{"path" => "allowed.txt", "content" => "allowed\n"},
                  %{id: "tc_write", index: 0}
                ),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: nil,
          config: agent_config(tool_approval: :destructive, destructive_tools: [])
        )

      assert :ok = send_prompt(pid, "Write the file")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000
      events = collect_run_events()

      refute Enum.any?(events, &match?(%Event.ToolApproval{}, &1))

      assert Enum.any?(
               events,
               &match?(%Event.ToolEnd{name: "write_file", is_error: false}, &1)
             )
    end

    test "destructive mode asks for names in the configured list", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "configured.txt"), "configured\n")
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call(
                  "read_file",
                  %{"path" => "configured.txt"},
                  %{id: "tc_read_configured", index: 0}
                ),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: nil,
          config: agent_config(tool_approval: :destructive, destructive_tools: ["read_file"])
        )

      assert :ok = send_prompt(pid, "Read the file")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000

      assert_receive {:agent_provider_event,
                      %Event.ToolApproval{
                        tool_call_id: "tc_read_configured",
                        reply_to: reply_to
                      }},
                     1_000

      send(reply_to, {:tool_approval_response, "tc_read_configured", :approve})
      events = collect_run_events()

      assert Enum.any?(
               events,
               &match?(%Event.ToolEnd{name: "read_file", is_error: false}, &1)
             )
    end

    test "custom spec approval metadata is honored", %{tmp_dir: dir} do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      spec =
        Spec.new!(
          source: :config,
          name: "custom_approval",
          description: "Requires approval",
          parameter_schema: %{},
          approval_level: :ask,
          build: fn _context ->
            fn _args ->
              send(test_pid, :custom_approval_ran)
              {:ok, "approved"}
            end
          end
        )

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count == 0 do
            [
              ReqLLM.StreamChunk.tool_call("custom_approval", %{}, %{
                id: "tc_custom_approval",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: [spec],
          config: agent_config(tool_approval: :destructive, destructive_tools: [])
        )

      assert :ok = send_prompt(pid, "Run custom tool")

      assert_receive {:agent_provider_event,
                      %Event.ToolApproval{
                        tool_call_id: "tc_custom_approval",
                        reply_to: reply_to
                      }},
                     1_000

      refute_receive :custom_approval_ran, 50
      send(reply_to, {:tool_approval_response, "tc_custom_approval", :approve})
      events = collect_run_events()

      assert_received :custom_approval_ran

      assert Enum.any?(
               events,
               &match?(%Event.ToolEnd{name: "custom_approval", is_error: false}, &1)
             )
    end

    test "approval-required tools wait while allowed tools continue", %{tmp_dir: dir} do
      test_pid = self()
      release_ref = make_ref()
      messages_ref = make_ref()
      call_count = :counters.new(1, [:atomics])

      ask_tool =
        ReqLLM.Tool.new!(
          name: "ask_tool",
          description: "Requires approval before running",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:tool_started, "ask_tool", self()})

            receive do
              {^release_ref, :release} -> {:ok, "approved result"}
            after
              1_000 -> {:error, "approval tool timed out"}
            end
          end
        )

      allowed_tool =
        ReqLLM.Tool.new!(
          name: "allowed_tool",
          description: "Runs without approval",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:tool_started, "allowed_tool", self()})

            receive do
              {^release_ref, :release} -> {:ok, "allowed result"}
            after
              1_000 -> {:error, "allowed tool timed out"}
            end
          end
        )

      client = fn _model, messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call("ask_tool", %{}, %{id: "tc_ask", index: 0}),
                ReqLLM.StreamChunk.tool_call("allowed_tool", %{}, %{id: "tc_allowed", index: 1}),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              send(test_pid, {messages_ref, messages})
              [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: [ask_tool, allowed_tool],
          config: agent_config(tool_permissions: %{"ask_tool" => :ask, "allowed_tool" => :allow})
        )

      assert :ok = send_prompt(pid, "Run both tools")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000

      assert_receive {:agent_provider_event,
                      %Event.ToolApproval{tool_call_id: "tc_ask", reply_to: reply_to}},
                     5_000

      assert_receive {:tool_started, "allowed_tool", allowed_pid}, 5_000
      send(reply_to, {:tool_approval_response, "tc_ask", :approve})
      assert_receive {:effect_admitted, "tc_ask"}, 5_000
      assert_receive {:tool_started, "ask_tool", ask_pid}, 5_000
      assert MapSet.member?(:sys.get_state(pid).tool_workers, ask_pid)
      send(ask_pid, {release_ref, :release})
      send(allowed_pid, {release_ref, :release})
      events = collect_run_events()
      assert Enum.any?(events, &match?(%Event.ToolEnd{name: "ask_tool", is_error: false}, &1))
      assert Enum.any?(events, &match?(%Event.ToolEnd{name: "allowed_tool", is_error: false}, &1))

      assert_received {^messages_ref, messages}
      tool_messages = Enum.filter(messages, fn message -> message.role == :tool end)
      assert Enum.map(tool_messages, & &1.tool_call_id) == ["tc_ask", "tc_allowed"]
    end

    test "rejected approval-required tool does not prevent an allowed sibling from finishing", %{
      tmp_dir: dir
    } do
      test_pid = self()
      release_ref = make_ref()
      messages_ref = make_ref()
      call_count = :counters.new(1, [:atomics])

      ask_tool =
        ReqLLM.Tool.new!(
          name: "reject_ask_tool",
          description: "Requires approval before running",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, :rejected_approval_tool_ran)
            {:ok, "should not run"}
          end
        )

      allowed_tool =
        ReqLLM.Tool.new!(
          name: "reject_allowed_tool",
          description: "Runs without approval",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:tool_started, "reject_allowed_tool", self()})

            receive do
              {^release_ref, :release} -> {:ok, "allowed result"}
            after
              1_000 -> {:error, "allowed tool timed out"}
            end
          end
        )

      client = fn _model, messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call("reject_ask_tool", %{}, %{id: "tc_reject", index: 0}),
                ReqLLM.StreamChunk.tool_call("reject_allowed_tool", %{}, %{
                  id: "tc_allowed",
                  index: 1
                }),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              send(test_pid, {messages_ref, messages})
              [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: [ask_tool, allowed_tool],
          config:
            agent_config(
              tool_permissions: %{"reject_ask_tool" => :ask, "reject_allowed_tool" => :allow}
            )
        )

      assert :ok = send_prompt(pid, "Run both tools")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000

      assert_receive {:agent_provider_event,
                      %Event.ToolApproval{tool_call_id: "tc_reject", reply_to: reply_to}},
                     5_000

      assert_receive {:tool_started, "reject_allowed_tool", allowed_pid}, 5_000
      send(reply_to, {:tool_approval_response, "tc_reject", :reject})
      send(allowed_pid, {release_ref, :release})
      events = collect_run_events()

      rejected_end = Enum.find(events, &match?(%Event.ToolEnd{name: "reject_ask_tool"}, &1))
      assert rejected_end != nil
      assert rejected_end.is_error == true
      assert rejected_end.result == "Tool rejected by user"

      assert Enum.any?(
               events,
               &match?(%Event.ToolEnd{name: "reject_allowed_tool", is_error: false}, &1)
             )

      assert_received {^messages_ref, messages}
      tool_messages = Enum.filter(messages, fn message -> message.role == :tool end)
      assert Enum.map(tool_messages, & &1.tool_call_id) == ["tc_reject", "tc_allowed"]

      assert Enum.map(tool_messages, &tool_message_text/1) == [
               "Tool rejected by user",
               "allowed result"
             ]

      assert Enum.map(tool_messages, & &1.metadata[:is_error]) == [true, nil]
      refute_received {:effect_admitted, "tc_reject"}
      refute_receive :rejected_approval_tool_ran, 50
    end

    test "tool approval mode :all preserves the batch prompt after per-tool ask overrides", %{
      tmp_dir: dir
    } do
      File.write!(Path.join(dir, "test.txt"), "file contents")
      File.mkdir_p!(Path.join(dir, "subdir"))
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                  id: "tc_1",
                  index: 0
                }),
                ReqLLM.StreamChunk.tool_call("list_directory", %{"path" => "."}, %{
                  id: "tc_2",
                  index: 1
                }),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              [
                ReqLLM.StreamChunk.text("done"),
                ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
              ]
          end

        build_stream_response(chunks)
      end

      tools = Tools.all(project_root: dir)

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: tools,
          config: agent_config(tool_approval: :all, tool_permissions: %{"read_file" => :ask})
        )

      assert :ok = send_prompt(pid, "Read the file and then list the directory")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000

      assert_receive {:agent_provider_event,
                      %Event.ToolApproval{tool_call_id: "tc_1", reply_to: reply_to_1}},
                     2_000

      send(reply_to_1, {:tool_approval_response, "tc_1", :approve})

      assert_receive {:agent_provider_event,
                      %Event.ToolApproval{tool_call_id: "tc_2", reply_to: reply_to_2}},
                     2_000

      send(reply_to_2, {:tool_approval_response, "tc_2", :approve})

      events = collect_run_events()

      assert Enum.any?(
               events,
               &match?(%Event.ToolStart{tool_call_id: "tc_1", name: "read_file"}, &1)
             )

      assert Enum.any?(
               events,
               &match?(
                 %Event.ToolEnd{tool_call_id: "tc_1", name: "read_file", is_error: false},
                 &1
               )
             )

      assert Enum.any?(
               events,
               &match?(%Event.ToolStart{tool_call_id: "tc_2", name: "list_directory"}, &1)
             )

      assert Enum.any?(
               events,
               &match?(
                 %Event.ToolEnd{tool_call_id: "tc_2", name: "list_directory", is_error: false},
                 &1
               )
             )

      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "uses ProjectView-backed tools when project_view is passed to Native.start_link", %{
      tmp_dir: dir
    } do
      root = Path.join(dir, "root")
      working_dir = Path.join(dir, "working")
      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(Path.join(working_dir, "lib"))
      File.write!(Path.join(root, "lib/file.txt"), "root text")
      File.write!(Path.join(working_dir, "lib/file.txt"), "view text")

      {:ok, project_view} =
        RecordingBackend.create(root,
          parent: self(),
          working_dir: working_dir,
          workspace_id: 7,
          env: [{"PROJECT_VIEW_SENTINEL", "present"}]
        )

      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count == 0 do
            [
              ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "lib/file.txt"}, %{
                id: "tc_project_view",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [
              ReqLLM.StreamChunk.text("done"),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(tmp_dir: root, llm_client: client, project_view: project_view, tools: nil)

      assert :ok = send_prompt(pid, "Read the file through ProjectView")

      events = collect_run_events()
      assert_received {:project_view_call, {:read_file, "lib/file.txt"}}
      tool_end = Enum.find(events, &match?(%Event.ToolEnd{name: "read_file"}, &1))
      assert tool_end != nil
      assert tool_end.result =~ "view text"
      assert tool_end.result =~ "ProjectView workspace 7"
    end

    test "tracks delete_file as a file change and marks the file deleted", %{tmp_dir: dir} do
      path = "delete-me.txt"
      absolute_path = Path.join(dir, path)
      File.write!(absolute_path, "delete me")

      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count == 0 do
            [
              ReqLLM.StreamChunk.tool_call("delete_file", %{"path" => path}, %{
                id: "tc_delete_file",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [
              ReqLLM.StreamChunk.text("deleted"),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: nil,
          config: agent_config(tool_approval: :none)
        )

      assert :ok = send_prompt(pid, "Delete the file")
      events = collect_run_events()

      assert Enum.any?(events, &match?(%Event.ToolStart{name: "delete_file"}, &1))
      assert Enum.any?(events, &match?(%Event.ToolEnd{name: "delete_file", is_error: false}, &1))

      file_changed = Enum.find(events, &match?(%Event.ToolFileChanged{}, &1))
      assert file_changed != nil
      assert file_changed.path == absolute_path
      assert file_changed.before_content == "delete me"
      assert file_changed.after_content == ""
      refute File.exists?(absolute_path)
    end

    test "tracks apply_diff as a file change through fork routing for an open buffer", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "patch-me.txt")
      absolute_path = path
      File.write!(absolute_path, "one\ntwo\n")
      buffer = start_supervised!({BufferProcess, file_path: absolute_path})
      diff = "@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n"
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count == 0 do
            [
              ReqLLM.StreamChunk.tool_call("apply_diff", %{"path" => path, "diff" => diff}, %{
                id: "tc_apply_diff",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [
              ReqLLM.StreamChunk.text("patched"),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: nil,
          config: agent_config(tool_approval: :none)
        )

      assert :ok = send_prompt(pid, "Patch the file")
      events = collect_run_events()

      assert Enum.any?(events, &match?(%Event.ToolStart{name: "apply_diff"}, &1))
      assert Enum.any?(events, &match?(%Event.ToolEnd{name: "apply_diff", is_error: false}, &1))

      file_changed = Enum.find(events, &match?(%Event.ToolFileChanged{}, &1))
      assert file_changed != nil
      assert file_changed.path == absolute_path
      assert file_changed.before_content == "one\ntwo\n"
      assert file_changed.after_content == "one\nTWO\n"
      assert BufferProcess.content(buffer) == "one\ntwo\n"
      assert File.read!(absolute_path) == "one\ntwo\n"
    end

    test "passes is_error metadata on tool result message when tool fails", %{tmp_dir: dir} do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])
      messages_ref = make_ref()

      client = fn _model, messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        send(test_pid, {messages_ref, count, messages})

        chunks =
          if count == 0 do
            [
              ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "nonexistent.txt"}, %{
                id: "tc_err",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [
              ReqLLM.StreamChunk.text("That file doesn't exist."),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks)
      end

      tools = Tools.all(project_root: dir)
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, tools: tools)
      :ok = send_prompt(pid, "Read nonexistent.txt")
      _events = collect_run_events()

      assert_received {^messages_ref, 1, messages}
      tool_msg = Enum.find(messages, fn m -> m.role == :tool end)
      assert tool_msg != nil
      assert tool_msg.metadata[:is_error] == true
    end
  end

  describe "send_prompt with LLM error" do
    test "emits error event on API failure", %{tmp_dir: dir} do
      client = fake_error_client("API rate limited")

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          max_retries: 0,
          model_selection: ModelSelectionFixture.selection(model_provider: "anthropic")
        )

      assert :ok = send_prompt(pid, "Hello")

      events = collect_run_events()

      error = Enum.find(events, &match?(%Event.Error{}, &1))
      assert error != nil
      assert %Event.Error{kind: :rate_limited, provider: "anthropic"} = error

      agent_end = Enum.find(events, &match?(%Event.AgentEnd{}, &1))
      assert agent_end != nil
    end

    test "surfaces a single failure exactly once", %{tmp_dir: dir} do
      # Regression: the agent loop emitted the error, and the Task-completion
      # handler emitted it again, so a single failure showed up twice in the
      # transcript. collect_run_events/1 stops at the first AgentEnd, so we
      # drain afterward to prove no second Error (or AgentEnd) follows.
      client = fake_error_client("boom once")
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_retries: 0)

      assert :ok = send_prompt(pid, "Hello")

      assert_receive {:agent_provider_event, %Event.Error{message: msg, kind: :provider_error}},
                     1_000

      assert msg ==
               "The model provider returned an unexpected error. Open Messages for details, or pick another configured model with /model."

      assert_receive {:agent_provider_event, %Event.AgentEnd{}}, 1_000

      refute_receive {:agent_provider_event, %Event.Error{}}, 200
      refute_receive {:agent_provider_event, %Event.AgentEnd{}}, 50
    end
  end

  describe "abort" do
    test "stops a running prompt", %{tmp_dir: dir} do
      {slow_stream, stream_ref} = blocking_text_stream()
      client = fn _model, _messages, _opts -> build_stream_response(slow_stream) end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)
      :ok = send_prompt(pid, "Tell me a very long story")
      assert_streaming_started(pid, stream_ref)

      assert :ok = Native.abort(pid)
      assert {:ok, %{is_streaming: false}} = Native.get_state(pid)
    end

    test "stops concurrent tool workers when aborted", %{tmp_dir: dir} do
      test_pid = self()
      marker_path = Path.join(dir, "abort-worker-continued.txt")
      release_ref = make_ref()
      call_count = :counters.new(1, [:atomics])

      blocking_tool =
        ReqLLM.Tool.new!(
          name: "abort_blocking_tool",
          description: "Blocks until the test releases it",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:abort_blocking_tool_started, self()})

            receive do
              {^release_ref, :release} ->
                File.write!(marker_path, "continued")
                send(test_pid, :abort_blocking_tool_continued)
                {:ok, "continued"}
            after
              5_000 ->
                {:error, "blocking tool timed out"}
            end
          end
        )

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call("abort_blocking_tool", %{}, %{
                  id: "tc_abort_blocking",
                  index: 0
                }),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, tools: [blocking_tool])

      assert :ok = send_prompt(pid, "Run the blocking tool")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000
      assert_receive {:abort_blocking_tool_started, worker_pid}, 5_000
      worker_ref = Process.monitor(worker_pid)

      assert :ok = Native.abort(pid)
      assert {:ok, %{is_streaming: false}} = Native.get_state(pid)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 5_000

      send(worker_pid, {release_ref, :release})
      refute_receive :abort_blocking_tool_continued, 50
      refute File.exists?(marker_path)
    end

    test "aborting with no active task still stops registered tool workers", %{tmp_dir: dir} do
      marker_path = Path.join(dir, "abort-nil-task-worker-continued.txt")
      test_pid = self()
      release_ref = make_ref()

      worker_pid =
        spawn(fn ->
          receive do
            {^release_ref, :release} ->
              File.write!(marker_path, "continued")
              send(test_pid, :abort_nil_task_worker_continued)
          end
        end)

      worker_ref = Process.monitor(worker_pid)
      {:ok, pid} = start_provider(tmp_dir: dir)
      :ok = GenServer.call(pid, {:register_tool_workers, [worker_pid]})

      assert :ok = Native.abort(pid)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 1_000

      send(worker_pid, {release_ref, :release})
      refute_receive :abort_nil_task_worker_continued, 50
      refute File.exists?(marker_path)
    end

    test "new_session stops concurrent tool workers", %{tmp_dir: dir} do
      test_pid = self()
      marker_path = Path.join(dir, "new-session-worker-continued.txt")
      release_ref = make_ref()
      call_count = :counters.new(1, [:atomics])

      blocking_tool =
        ReqLLM.Tool.new!(
          name: "new_session_blocking_tool",
          description: "Blocks until the test releases it",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:new_session_blocking_tool_started, self()})

            receive do
              {^release_ref, :release} ->
                File.write!(marker_path, "continued")
                send(test_pid, :new_session_blocking_tool_continued)
                {:ok, "continued"}
            after
              5_000 ->
                {:error, "blocking tool timed out"}
            end
          end
        )

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call("new_session_blocking_tool", %{}, %{
                  id: "tc_new_session_blocking",
                  index: 0
                }),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
          end

        build_stream_response(chunks)
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, tools: [blocking_tool])

      assert :ok = send_prompt(pid, "Run the blocking tool")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000
      assert_receive {:new_session_blocking_tool_started, worker_pid}, 1_000
      worker_ref = Process.monitor(worker_pid)

      assert :ok = Native.new_session(pid)
      assert {:ok, %{is_streaming: false}} = Native.get_state(pid)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 1_000

      send(worker_pid, {release_ref, :release})
      refute_receive :new_session_blocking_tool_continued, 50
      refute File.exists?(marker_path)
    end
  end

  describe "stream recovery" do
    test "preserves partial text when stream drops mid-response", %{tmp_dir: dir} do
      client = fn _model, _messages, _opts ->
        error_stream =
          Stream.resource(
            fn -> 0 end,
            fn
              0 -> {[ReqLLM.StreamChunk.text("Hello, I was saying something ")], 1}
              1 -> {[ReqLLM.StreamChunk.text("important about ")], 2}
              2 -> raise "connection reset by peer"
            end,
            fn _ -> :ok end
          )

        build_stream_response(error_stream)
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_retries: 0)
      :ok = send_prompt(pid, "Tell me something important")

      events = collect_run_events()

      # Should have streamed the partial text before the error
      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      streamed_text = Enum.map_join(text_deltas, & &1.delta)
      assert streamed_text =~ "Hello, I was saying something"
      assert streamed_text =~ "important about"

      # Should have an interruption notice
      assert streamed_text =~ "Stream interrupted"

      # Should have AgentEnd (not left hanging)
      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "continue resumes without replaying an incomplete assistant turn", %{tmp_dir: dir} do
      parent = self()
      call_count = :counters.new(1, [:atomics])

      client = fn _model, messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          error_stream =
            Stream.resource(
              fn -> 0 end,
              fn
                0 -> {[ReqLLM.StreamChunk.text("Partial response here")], 1}
                1 -> raise "connection reset"
              end,
              fn _ -> :ok end
            )

          build_stream_response(error_stream)
        else
          send(parent, {:continued_messages, messages})

          build_stream_response([
            ReqLLM.StreamChunk.text("Continuing from where I left off."),
            ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
          ])
        end
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_retries: 0)

      :ok = send_prompt(pid, "Tell me something")
      _events1 = collect_run_events()

      :ok = continue(pid)
      events2 = collect_run_events()

      assert_received {:continued_messages, messages}

      refute Enum.any?(
               messages,
               &(&1.role == :assistant and text_content(&1) =~ "Partial response here")
             )

      text_deltas = Enum.filter(events2, &match?(%Event.TextDelta{}, &1))
      continued_text = Enum.map_join(text_deltas, & &1.delta)
      assert continued_text =~ "Continuing from where I left off"
    end

    test "does not execute or replay tool calls from an incomplete response", %{tmp_dir: dir} do
      parent = self()
      call_count = :counters.new(1, [:atomics])

      side_effect_tool =
        Spec.new!(
          source: :config,
          name: "side_effect",
          description: "Records whether the tool is executed",
          parameter_schema: %{},
          build: fn _context ->
            fn _args ->
              send(parent, :side_effect_executed)
              {:ok, "executed"}
            end
          end
        )

      client = fn _model, messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          build_stream_response(
            [
              ReqLLM.StreamChunk.tool_call("side_effect", %{}, %{
                id: "tc_incomplete",
                index: 0,
                expects_arg_fragments: true
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_calls})
            ],
            %{},
            %{finish_reason: :tool_calls}
          )
        else
          send(parent, {:continued_messages, messages})

          build_stream_response([
            ReqLLM.StreamChunk.text("Recovered."),
            ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
          ])
        end
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: [side_effect_tool]
        )

      assert :ok = send_prompt(pid, "Run the tool")
      first_events = collect_run_events()

      assert Enum.any?(first_events, fn
               %Event.TextDelta{delta: delta} -> String.contains?(delta, "incomplete")
               _event -> false
             end)

      refute_received :side_effect_executed

      assert :ok = continue(pid)
      _continued_events = collect_run_events()

      assert_received {:continued_messages, messages}
      refute Enum.any?(messages, &(&1.role == :assistant and is_list(&1.tool_calls)))
      refute_received :side_effect_executed
    end

    test "accepts Session-provided continuation without provider-local interruption history", %{
      tmp_dir: dir
    } do
      chunks = [
        ReqLLM.StreamChunk.text("Complete response"),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ]

      client = fake_llm_client(chunks)
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)

      assert :ok = send_prompt(pid, "Hello")
      collect_run_events()

      assert :ok = continue(pid)
      assert Enum.any?(collect_run_events(), &match?(%Event.AgentEnd{outcome: %{}}, &1))
    end

    test "continue fails while already streaming", %{tmp_dir: dir} do
      {slow_stream, stream_ref} = blocking_text_stream()
      client = fn _model, _messages, _opts -> build_stream_response(slow_stream) end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)
      :ok = send_prompt(pid, "Long story")
      assert_streaming_started(pid, stream_ref)

      assert {:error, "Already streaming"} = continue(pid)

      Native.abort(pid)
    end

    test "small partial text does not trigger recovery", %{tmp_dir: dir} do
      # Stream only a few characters, then error - should get a normal error, not recovery
      client = fn _model, _messages, _opts ->
        error_stream =
          Stream.resource(
            fn -> 0 end,
            fn
              0 -> {[ReqLLM.StreamChunk.text("Hi")], 1}
              1 -> raise "connection reset"
            end,
            fn _ -> :ok end
          )

        build_stream_response(error_stream)
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_retries: 0)
      :ok = send_prompt(pid, "Hello")

      events = collect_run_events()

      # Should get a normal error, not the recovery path
      error_events = Enum.filter(events, &match?(%Event.Error{}, &1))
      assert error_events != []
    end
  end

  describe "concurrent prompt rejection" do
    test "rejects second prompt while streaming", %{tmp_dir: dir} do
      {slow_stream, _stream_ref} = blocking_text_stream()
      client = fn _model, _messages, _opts -> build_stream_response(slow_stream) end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)
      :ok = send_prompt(pid, "First prompt")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}
      assert {:ok, %{is_streaming: true}} = Native.get_state(pid)

      assert {:error, :already_streaming} = send_prompt(pid, "Second prompt")

      Native.abort(pid)
    end
  end

  # ── Turn limit tests (#401) ────────────────────────────────────────────────

  describe "turn limit" do
    test "stops the agent loop when turn limit is reached", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "hello")

      # Create a client that always makes tool calls (simulating a runaway loop).
      # Each call returns a tool_call, which triggers another turn.
      client = fn _model, _messages, _opts ->
        chunks = [
          ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
            id: "tc_#{:erlang.unique_integer([:positive])}",
            index: 0
          }),
          ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
        ]

        build_stream_response(chunks)
      end

      tools = Tools.all(project_root: dir)

      {:ok, pid} =
        start_provider(tmp_dir: dir, llm_client: client, tools: tools, max_turns: 3)

      :ok = send_prompt(pid, "Read the file over and over")

      events = collect_run_events()

      # Should have a turn limit warning
      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      all_text = Enum.map_join(text_deltas, & &1.delta)
      assert all_text =~ "Turn limit reached"
      assert all_text =~ "3/3"

      # Should have a TurnLimitReached event
      turn_limit_events = Enum.filter(events, &match?(%Event.TurnLimitReached{}, &1))
      assert [%Event.TurnLimitReached{current: 3, limit: 3}] = turn_limit_events

      # Should have ended cleanly
      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "normal tool-call loops within the limit complete successfully", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "content")

      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count < 2 do
            [
              ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                id: "tc_#{count}",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [
              ReqLLM.StreamChunk.text("Done reading."),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks)
      end

      tools = Tools.all(project_root: dir)

      {:ok, pid} =
        start_provider(tmp_dir: dir, llm_client: client, tools: tools, max_turns: 10)

      :ok = send_prompt(pid, "Read the file twice")

      events = collect_run_events()

      # Should NOT have a turn limit warning
      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      all_text = Enum.map_join(text_deltas, & &1.delta)
      refute all_text =~ "Turn limit reached"

      # Should have completed normally with "Done reading."
      assert all_text =~ "Done reading."
    end

    test "continue after turn limit resets the turn counter", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "hello")

      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count < 5 do
            [
              ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                id: "tc_#{count}",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [
              ReqLLM.StreamChunk.text("Finally done."),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks)
      end

      tools = Tools.all(project_root: dir)

      {:ok, pid} =
        start_provider(tmp_dir: dir, llm_client: client, tools: tools, max_turns: 2)

      # First prompt hits the limit after 2 turns
      :ok = send_prompt(pid, "Keep reading")
      events1 = collect_run_events()

      text1 = events1 |> Enum.filter(&match?(%Event.TextDelta{}, &1)) |> Enum.map_join(& &1.delta)
      assert text1 =~ "Turn limit reached"

      # Continue should reset the counter and keep going
      :ok = continue(pid)
      events2 = collect_run_events()

      text2 = events2 |> Enum.filter(&match?(%Event.TextDelta{}, &1)) |> Enum.map_join(& &1.delta)
      # It will hit the limit again (2 more turns), or finish if the counter went past 5
      assert text2 =~ "Turn limit reached" or text2 =~ "Finally done."
    end
  end

  # ── Cost budget tests (#404) ────────────────────────────────────────────────

  describe "cost budget" do
    test "normalizes raw usage and reports prompt guidance", %{tmp_dir: dir} do
      usage = %{
        input_tokens: 1000,
        output_tokens: 500,
        cache_read_input_tokens: 750,
        cache_creation_input_tokens: 100,
        total_cost: 0.05
      }

      client =
        fake_llm_client(
          [ReqLLM.StreamChunk.text("Hello"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})],
          usage
        )

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_cost: 5.0)

      assert {:ok, session_state} = Native.get_state(pid)

      assert session_state.system_prompt =~
               "list_directory: List entries at a known-small path. Bounded and ignores generated trees."

      assert session_state.system_prompt =~
               "Do not use shell to recursively list or search files when find or grep can answer the question."

      :ok = send_prompt(pid, "test")
      events = collect_run_events()

      assert %Event.AgentEnd{
               usage: %TurnUsage{
                 input: 1000,
                 output: 500,
                 cache_read: 750,
                 cache_write: 100,
                 cost: 0.05
               }
             } =
               Enum.find(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "normalizes ReqLLM canonical cache usage fields", %{tmp_dir: dir} do
      usage = %{
        input_tokens: 1100,
        output_tokens: 550,
        cached_input: 800,
        cache_creation: 120,
        total_cost: 0.06
      }

      client =
        fake_llm_client(
          [ReqLLM.StreamChunk.text("Hello"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})],
          usage
        )

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_cost: 5.0)
      :ok = send_prompt(pid, "test")
      events = collect_run_events()

      assert %Event.AgentEnd{
               usage: %TurnUsage{
                 input: 1100,
                 output: 550,
                 cache_read: 800,
                 cache_write: 120,
                 cost: 0.06
               }
             } = Enum.find(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "normalizes fallback usage fields", %{tmp_dir: dir} do
      usage = %{input: 1100, output: 550, cache_write: 120, cost: 0.06}

      client =
        fake_llm_client(
          [ReqLLM.StreamChunk.text("Hello"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})],
          usage
        )

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_cost: 5.0)
      :ok = send_prompt(pid, "test")
      events = collect_run_events()

      assert %Event.AgentEnd{
               usage: %TurnUsage{
                 input: 1100,
                 output: 550,
                 cache_read: 0,
                 cache_write: 120,
                 cost: 0.06
               }
             } = Enum.find(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "keeps explicit zero usage values", %{tmp_dir: dir} do
      usage = %{input_tokens: 0, input: 1100, output_tokens: 0, output: 550, total_cost: 0.0}

      client =
        fake_llm_client(
          [ReqLLM.StreamChunk.text("Hello"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})],
          usage
        )

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_cost: 5.0)
      :ok = send_prompt(pid, "test")
      events = collect_run_events()

      assert %Event.AgentEnd{usage: %TurnUsage{input: 0, output: 0, cost: cost}} =
               Enum.find(events, &match?(%Event.AgentEnd{}, &1))

      assert cost == 0.0
    end

    test "budget can be read, changed, disabled, and reset by new_session", %{tmp_dir: dir} do
      usage = %{input_tokens: 1000, output_tokens: 500, total_cost: 0.05}

      client =
        fake_llm_client(
          [ReqLLM.StreamChunk.text("Hello"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})],
          usage
        )

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_cost: 5.0)

      assert {:ok, budget} = GenServer.call(pid, :get_budget)
      assert budget.session_cost == 0.0
      assert budget.max_cost == 5.0
      assert budget.max_turns == 100

      assert :ok = GenServer.call(pid, {:set_max_cost, 10.0})
      assert {:ok, %{max_cost: 10.0}} = GenServer.call(pid, :get_budget)

      assert :ok = GenServer.call(pid, {:set_max_cost, nil})
      assert {:ok, %{max_cost: nil}} = GenServer.call(pid, :get_budget)

      :ok = send_prompt(pid, "test")
      collect_run_events()

      :ok = Native.new_session(pid)
      assert {:ok, budget} = GenServer.call(pid, :get_budget)
      assert budget.session_cost == 0.0
    end

    test "preflight cost limit does not wedge streaming and recovers after budget increase", %{
      tmp_dir: dir
    } do
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          build_stream_response(
            [
              ReqLLM.StreamChunk.text("Initial"),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ],
            %{total_cost: 2.0}
          )
        else
          build_stream_response([
            ReqLLM.StreamChunk.text("Recovered"),
            ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
          ])
        end
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_cost: 1.0)

      assert :ok = send_prompt(pid, "initial prompt")
      initial_events = collect_run_events()
      assert Enum.any?(initial_events, &match?(%Event.TextDelta{delta: "Initial"}, &1))
      assert Enum.any?(initial_events, &match?(%Event.AgentEnd{}, &1))
      assert {:ok, %{session_cost: 2.0}} = GenServer.call(pid, :get_budget)

      assert {:error, :cost_limit_reached} = send_prompt(pid, "blocked by budget")

      assert_receive {:agent_provider_event, %Event.Error{message: message}}, 1_000
      assert message =~ "Session cost limit reached"
      refute_received {:agent_provider_event, %Event.AgentStart{}}
      assert {:ok, %{is_streaming: false}} = Native.get_state(pid)

      assert :ok = GenServer.call(pid, {:set_max_cost, 3.0})
      assert :ok = send_prompt(pid, "after budget increase")

      events = collect_run_events()
      assert Enum.any?(events, &match?(%Event.TextDelta{delta: "Recovered"}, &1))
      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
      assert {:ok, %{is_streaming: false}} = Native.get_state(pid)
    end

    test "agent stops when cost budget is exceeded during tool loop", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "hello")

      client = fn _model, _messages, _opts ->
        chunks = [
          ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
            id: "tc_#{:erlang.unique_integer([:positive])}",
            index: 0
          }),
          ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
        ]

        build_stream_response(chunks, %{
          input_tokens: 10_000,
          output_tokens: 5_000,
          total_cost: 1.0
        })
      end

      tools = Tools.all(project_root: dir)

      # Set a $2 budget; each turn costs $1, so it should stop after 2 turns
      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: tools,
          max_cost: 2.0,
          max_turns: 100
        )

      :ok = send_prompt(pid, "Keep reading forever")

      events = collect_run_events()

      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      all_text = Enum.map_join(text_deltas, & &1.delta)

      assert all_text =~ "cost limit reached" or all_text =~ "Session cost limit reached"

      # Should have ended
      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "nil max_cost means no cost limit", %{tmp_dir: dir} do
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count < 3 do
            [
              ReqLLM.StreamChunk.text("turn #{count} "),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          else
            [
              ReqLLM.StreamChunk.text("done"),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks, %{total_cost: 100.0})
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_cost: nil)

      :ok = send_prompt(pid, "test")
      events = collect_run_events()

      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      all_text = Enum.map_join(text_deltas, & &1.delta)
      refute all_text =~ "cost limit"
    end
  end

  describe "exact request endpoint" do
    test "the active resolved endpoint cannot be replaced by mutable config defaults", %{
      tmp_dir: dir
    } do
      parent = self()
      selection = ModelSelectionFixture.selection(base_url: "http://127.0.0.1:9000/v1")

      config =
        agent_config(
          api_base_url_override: "https://wrong-override.example/v1",
          api_base_url: "https://wrong-default.example/v1",
          api_endpoints: %{"openai" => "https://wrong-provider.example/v1"}
        )

      client = fn model, _messages, opts ->
        send(parent, {:executed_route, model.base_url, opts})
        build_stream_response([{:text, "ok"}])
      end

      {:ok, provider} =
        start_provider(
          tmp_dir: dir,
          model_selection: selection,
          llm_client: client,
          config: config
        )

      assert :ok = send_prompt(provider, "Use the active route")
      assert_receive {:executed_route, "http://127.0.0.1:9000/v1", opts}, 2_000
      refute Keyword.has_key?(opts, :base_url)
      assert Enum.any?(collect_run_events(), &match?(%Event.AgentEnd{}, &1))
    end
  end

  # ── Model format validation ──────────────────────────────────────────────────

  describe "provider error formatting" do
    test "missing API key provider build errors are human-readable and log raw detail", %{
      tmp_dir: tmp_dir
    } do
      reason =
        {:http_streaming_failed,
         {:provider_build_failed,
          %{reason: "Failed to build Anthropic stream request: api_key=sk-testsecret123"}}}

      {:ok, pid} =
        start_provider(
          model_selection: ModelSelectionFixture.selection(model_provider: "anthropic"),
          llm_client: fake_error_client(reason),
          tmp_dir: tmp_dir,
          max_retries: 0
        )

      log =
        capture_log(fn ->
          send_prompt(pid, "hello")
          events = collect_run_events()

          error = Enum.find(events, &match?(%Event.Error{}, &1))

          assert %Event.Error{message: message, kind: :auth_failed, provider: "anthropic"} =
                   error

          refute message =~ "ReqLLM"
          refute message =~ "Splode"
          refute message =~ "bread_crumbs"
        end)

      assert log =~ "agent loop detail:"
      assert log =~ "[REDACTED]"
      refute log =~ "sk-testsecret123"
    end

    test "openai codex auth failures suggest /login instead of /auth openai_codex", %{
      tmp_dir: tmp_dir
    } do
      {:ok, pid} =
        start_provider(
          model_selection: ModelSelectionFixture.selection(model_provider: "openai_codex"),
          llm_client: fake_error_client("Unauthorized"),
          tmp_dir: tmp_dir,
          max_retries: 0
        )

      send_prompt(pid, "hello")
      events = collect_run_events()

      error = Enum.find(events, &match?(%Event.Error{}, &1))

      assert %Event.Error{message: message, kind: :auth_failed, provider: "openai_codex"} =
               error

      assert message =~ "/login"
      refute message =~ "/auth openai_codex"
    end

    test "openai codex chatgpt account model incompatibility is actionable invalid_model", %{
      tmp_dir: tmp_dir
    } do
      reason = %{
        reason: "HTTP 400",
        status: 400,
        response_body: %{
          "detail" =>
            "The 'gpt-5.3-codex' model is not supported when using Codex with a ChatGPT account."
        }
      }

      {:ok, pid} =
        start_provider(
          model_selection: ModelSelectionFixture.selection(model_provider: "openai_codex"),
          llm_client: fake_error_client(reason),
          tmp_dir: tmp_dir,
          max_retries: 0
        )

      send_prompt(pid, "hello")
      events = collect_run_events()

      error = Enum.find(events, &match?(%Event.Error{}, &1))

      assert %Event.Error{kind: :invalid_model, provider: "openai_codex"} = error
    end

    test "string-only provider errors classify auth, rate limit, and network failures", %{
      tmp_dir: tmp_dir
    } do
      cases = [
        {"Unauthorized", :auth_failed},
        {"invalid_api_key", :auth_failed},
        {"401", :auth_failed},
        {"403", :auth_failed},
        {"API rate limited", :rate_limited},
        {"rate limit", :rate_limited},
        {"429", :rate_limited},
        {"timeout", :unreachable},
        {"nxdomain", :unreachable},
        {"econnrefused", :unreachable}
      ]

      Enum.each(cases, fn {reason, kind} ->
        {:ok, pid} =
          start_provider(
            model_selection: ModelSelectionFixture.selection(model_provider: "anthropic"),
            llm_client: fake_error_client(reason),
            tmp_dir: tmp_dir,
            max_retries: 0
          )

        send_prompt(pid, "hello")
        events = collect_run_events()

        error = Enum.find(events, &match?(%Event.Error{}, &1))
        assert %Event.Error{kind: ^kind} = error
      end)
    end
  end
end
