defmodule MingaAgent.Providers.NativeTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.ProjectView
  alias MingaAgent.Event
  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.Providers.Native
  alias MingaAgent.Tools
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

  defp build_stream_response(chunks, usage \\ %{}) do
    # MetadataHandle is a GenServer that returns metadata when awaited.
    {:ok, handle} =
      MetadataHandle.start_link(fn ->
        %{usage: usage, finish_reason: :stop}
      end)

    stream_response = %ReqLLM.StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: elem(ReqLLM.model("anthropic:claude-sonnet-4-20250514"), 1),
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

  defp fake_error_client(error_reason) do
    fn _model, _messages, _opts ->
      {:error, error_reason}
    end
  end

  defp start_provider(opts) do
    defaults = [
      subscriber: self(),
      model: "anthropic:claude-sonnet-4-20250514",
      config: %AgentConfig{},
      project_root: opts[:tmp_dir] || System.tmp_dir!(),
      tools: [],
      skip_api_key_env: true
    ]

    merged = Keyword.merge(defaults, opts)
    Native.start_link(merged)
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
  defp collect_events(timeout) do
    collect_events_acc([], timeout)
  end

  defp collect_events_acc(acc, timeout) do
    receive do
      {:agent_provider_event, %Event.AgentEnd{} = event} ->
        # AgentEnd is always the last event; return immediately
        Enum.reverse([event | acc])

      {:agent_provider_event, event} ->
        collect_events_acc([event | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
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
      assert session_state.model.provider == "native"
      assert session_state.model.id == "anthropic:claude-sonnet-4-20250514"
      assert session_state.is_streaming == false
      assert session_state.thinking_level == "high"
      assert session_state.active_skill_names == ["plan"]
      assert session_state.project_root == dir
      assert session_state.system_prompt =~ "PLAN SKILL 1419"
      assert session_state.system_prompt =~ "PROJECT RULE 1419"
    end

    test "thinking level accepts known values, rejects unknown values, and cycles in order", %{
      tmp_dir: dir
    } do
      {:ok, pid} = start_provider(tmp_dir: dir)

      for level <- ["low", "medium", "high", "off"] do
        assert :ok = Native.set_thinking_level(pid, level)
      end

      assert {:error, msg} = Native.set_thinking_level(pid, "turbo")
      assert msg =~ "unknown thinking level"

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
        {"openai:o3-mini", "off", nil}
      ]

      Enum.each(cases, fn {model, thinking_level, expected_effort} ->
        test_pid = self()
        ref = make_ref()

        client = fn captured_model, _messages, opts ->
          send(test_pid, {ref, captured_model, opts})
          build_stream_response([ReqLLM.StreamChunk.text("ok")])
        end

        {:ok, pid} =
          start_provider(
            tmp_dir: dir,
            model: model,
            thinking_level: thinking_level,
            llm_client: client
          )

        assert :ok = Native.send_prompt(pid, "test")
        assert_receive {^ref, ^model, opts}, 2_000

        if expected_effort do
          assert Keyword.get(opts, :reasoning_effort) == expected_effort
        else
          refute Keyword.has_key?(opts, :reasoning_effort)
        end

        provider_options = Keyword.get(opts, :provider_options, [])
        refute Keyword.has_key?(provider_options, :additional_model_request_fields)

        collect_events(500)
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

      :ok = Native.send_prompt(pid, "Hello")
      collect_events(500)

      assert :ok = Native.set_model(pid, "openai:o4-mini")
      assert {:ok, state} = Native.get_state(pid)
      assert state.model.id == "openai:o4-mini"
      assert state.thinking_level == "medium"

      :ok = Native.send_prompt(pid, "Follow up")
      collect_events(500)

      assert_received {^messages_ref, 1, "openai:o4-mini", messages}
      assert length(messages) >= 4
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

      assert :ok = Native.send_prompt(pid, "Hi")

      events = collect_events(500)
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

      assert :ok = Native.send_prompt(pid, "Read test.txt")

      events = collect_events(1_000)

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

      assert :ok = Native.send_prompt(pid, "Read the file and then list the directory")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 1_000

      assert_receive {:agent_provider_event,
                      %Event.ToolApproval{tool_call_id: "tc_1", reply_to: reply_to_1}},
                     1_000

      send(reply_to_1, {:tool_approval_response, "tc_1", :approve})

      assert_receive {:agent_provider_event,
                      %Event.ToolStart{tool_call_id: "tc_1", name: "read_file"}},
                     1_000

      assert_receive {:agent_provider_event,
                      %Event.ToolEnd{tool_call_id: "tc_1", name: "read_file", is_error: false}},
                     1_000

      assert_receive {:agent_provider_event,
                      %Event.ToolApproval{tool_call_id: "tc_2", reply_to: reply_to_2}},
                     1_000

      send(reply_to_2, {:tool_approval_response, "tc_2", :approve})

      assert_receive {:agent_provider_event,
                      %Event.ToolStart{tool_call_id: "tc_2", name: "list_directory"}},
                     1_000

      assert_receive {:agent_provider_event,
                      %Event.ToolEnd{
                        tool_call_id: "tc_2",
                        name: "list_directory",
                        is_error: false
                      }},
                     1_000

      assert_receive {:agent_provider_event, %Event.AgentEnd{}}, 1_000
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

      assert :ok = Native.send_prompt(pid, "Read the file through ProjectView")

      events = collect_events(2_000)
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

      assert :ok = Native.send_prompt(pid, "Delete the file")
      events = collect_events(1_000)

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

      assert :ok = Native.send_prompt(pid, "Patch the file")
      events = collect_events(1_000)

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
      :ok = Native.send_prompt(pid, "Read nonexistent.txt")
      _events = collect_events(1_000)

      assert_received {^messages_ref, 1, messages}
      tool_msg = Enum.find(messages, fn m -> m.role == :tool end)
      assert tool_msg != nil
      assert tool_msg.metadata[:is_error] == true
    end
  end

  describe "send_prompt with LLM error" do
    test "emits error event on API failure", %{tmp_dir: dir} do
      client = fake_error_client("API rate limited")
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_retries: 0)

      assert :ok = Native.send_prompt(pid, "Hello")

      events = collect_events(500)

      error = Enum.find(events, &match?(%Event.Error{}, &1))
      assert error != nil
      assert error.message =~ "API rate limited"

      agent_end = Enum.find(events, &match?(%Event.AgentEnd{}, &1))
      assert agent_end != nil
    end
  end

  describe "abort" do
    test "stops a running prompt", %{tmp_dir: dir} do
      {slow_stream, stream_ref} = blocking_text_stream()
      client = fn _model, _messages, _opts -> build_stream_response(slow_stream) end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)
      :ok = Native.send_prompt(pid, "Tell me a very long story")
      assert_streaming_started(pid, stream_ref)

      assert :ok = Native.abort(pid)
      assert {:ok, %{is_streaming: false}} = Native.get_state(pid)
    end
  end

  describe "stream recovery" do
    test "preserves partial text when stream drops mid-response", %{tmp_dir: dir} do
      # Create a stream that emits some text then raises an error
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
      :ok = Native.send_prompt(pid, "Tell me something important")

      events = collect_events(1_000)

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

    test "continue resumes after interrupted stream", %{tmp_dir: dir} do
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          # First call: stream drops mid-response
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
          # Second call (continue): complete response
          chunks = [
            ReqLLM.StreamChunk.text("Continuing from where I left off."),
            ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
          ]

          build_stream_response(chunks)
        end
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_retries: 0)

      # First prompt gets interrupted
      :ok = Native.send_prompt(pid, "Tell me something")
      _events1 = collect_events(1_000)

      # Continue should work
      :ok = Native.continue(pid)
      events2 = collect_events(1_000)

      text_deltas = Enum.filter(events2, &match?(%Event.TextDelta{}, &1))
      continued_text = Enum.map_join(text_deltas, & &1.delta)
      assert continued_text =~ "Continuing from where I left off"
    end

    test "continue fails when no stream was interrupted", %{tmp_dir: dir} do
      chunks = [
        ReqLLM.StreamChunk.text("Complete response"),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ]

      client = fake_llm_client(chunks)
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)

      :ok = Native.send_prompt(pid, "Hello")
      _events = collect_events(500)

      assert {:error, "No interrupted response to continue from"} = Native.continue(pid)
    end

    test "continue fails while already streaming", %{tmp_dir: dir} do
      {slow_stream, stream_ref} = blocking_text_stream()
      client = fn _model, _messages, _opts -> build_stream_response(slow_stream) end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)
      :ok = Native.send_prompt(pid, "Long story")
      assert_streaming_started(pid, stream_ref)

      assert {:error, "Already streaming"} = Native.continue(pid)

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
      :ok = Native.send_prompt(pid, "Hello")

      events = collect_events(1_000)

      # Should get a normal error, not the recovery path
      error_events = Enum.filter(events, &match?(%Event.Error{}, &1))
      assert error_events != []
    end
  end

  describe "concurrent prompt rejection" do
    test "rejects second prompt while streaming", %{tmp_dir: dir} do
      {slow_stream, stream_ref} = blocking_text_stream()
      client = fn _model, _messages, _opts -> build_stream_response(slow_stream) end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)
      :ok = Native.send_prompt(pid, "First prompt")
      assert_streaming_started(pid, stream_ref)

      assert {:error, :already_streaming} = Native.send_prompt(pid, "Second prompt")

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

      :ok = Native.send_prompt(pid, "Read the file over and over")

      events = collect_events(3_000)

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

      :ok = Native.send_prompt(pid, "Read the file twice")

      events = collect_events(3_000)

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
      :ok = Native.send_prompt(pid, "Keep reading")
      events1 = collect_events(3_000)

      text1 = events1 |> Enum.filter(&match?(%Event.TextDelta{}, &1)) |> Enum.map_join(& &1.delta)
      assert text1 =~ "Turn limit reached"

      # Continue should reset the counter and keep going
      :ok = Native.continue(pid)
      events2 = collect_events(3_000)

      text2 = events2 |> Enum.filter(&match?(%Event.TextDelta{}, &1)) |> Enum.map_join(& &1.delta)
      # It will hit the limit again (2 more turns), or finish if the counter went past 5
      assert text2 =~ "Turn limit reached" or text2 =~ "Finally done."
    end
  end

  # ── Cost budget tests (#404) ────────────────────────────────────────────────

  describe "cost budget" do
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

      :ok = Native.send_prompt(pid, "test")
      collect_events(500)

      :ok = Native.new_session(pid)
      assert {:ok, budget} = GenServer.call(pid, :get_budget)
      assert budget.session_cost == 0.0
    end

    test "agent stops when cost budget is exceeded during tool loop", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "hello")

      # Create a client where each turn has a significant cost
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

      :ok = Native.send_prompt(pid, "Keep reading forever")

      events = collect_events(5_000)

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

      :ok = Native.send_prompt(pid, "test")
      events = collect_events(1_000)

      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      all_text = Enum.map_join(text_deltas, & &1.delta)
      refute all_text =~ "cost limit"
    end
  end

  describe "custom API base URL" do
    test "base_url option follows override, per-provider, global, and unset precedence", %{
      tmp_dir: dir
    } do
      cases = [
        {agent_config(api_base_url_override: "https://gateway.corp.com/v1"),
         "https://gateway.corp.com/v1"},
        {%AgentConfig{}, nil},
        {agent_config(
           api_base_url: "https://global.example.com/v1",
           api_endpoints: %{
             "anthropic" => "https://anthropic-gw.corp.com/v1",
             "openai" => "https://openai-gw.corp.com/v1"
           }
         ), "https://anthropic-gw.corp.com/v1"},
        {agent_config(
           api_base_url: "https://global.example.com/v1",
           api_endpoints: %{"openai" => "https://openai-only.com/v1"}
         ), "https://global.example.com/v1"},
        {agent_config(
           api_base_url_override: "https://env-override.com/v1",
           api_endpoints: %{"anthropic" => "https://should-lose.com"}
         ), "https://env-override.com/v1"}
      ]

      for {config, expected_base_url} <- cases do
        ref = make_ref()
        test_pid = self()

        capturing_client = fn _model, _messages, opts ->
          send(test_pid, {ref, opts})
          build_stream_response([{:text, "ok"}])
        end

        {:ok, pid} = start_provider(tmp_dir: dir, llm_client: capturing_client, config: config)
        :ok = Native.send_prompt(pid, "test")

        assert_receive {^ref, opts}, 2_000

        if expected_base_url do
          assert Keyword.get(opts, :base_url) == expected_base_url
        else
          refute Keyword.has_key?(opts, :base_url)
        end

        collect_events(500)
      end
    end
  end

  # ── Model format validation ──────────────────────────────────────────────────

  describe "model format validation" do
    test "bare model name without provider prefix returns :invalid_format error", %{
      tmp_dir: tmp_dir
    } do
      # A model name like "claude-sonnet-4" (no provider prefix) should
      # fail with a clear error, not a cryptic :invalid_format atom.
      {:ok, pid} =
        start_provider(
          model: "claude-sonnet-4",
          llm_client: fake_llm_client([]),
          tmp_dir: tmp_dir
        )

      Native.send_prompt(pid, "hello")
      events = collect_events(2_000)

      error_events = Enum.filter(events, &match?(%Event.Error{}, &1))
      assert error_events != []

      error = hd(error_events)
      assert error.message =~ "missing a provider prefix"
      assert error.message =~ "provider:model"
    end
  end
end
