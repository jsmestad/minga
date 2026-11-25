defmodule MingaAgent.Providers.NativeCwdTest do
  # Changes the VM-global working directory to verify that a session without a project never works there.
  use Minga.Test.SessionCase, async: false

  alias MingaAgent.ProjectView
  alias MingaAgent.Test.RecordingProcessBackend
  alias MingaAgent.ToolCall
  alias ReqLLM.StreamChunk

  @moduletag :tmp_dir
  @moduletag :heavy

  test "find is declined, and the process directory is never searched, when no project is active",
       %{tmp_dir: dir} do
    dir = Path.expand(dir)
    cwd = Path.join(dir, "cwd")
    File.mkdir_p!(cwd)
    sample = "defmodule Sample, do: nil\n"
    File.write!(Path.join(cwd, "sample.ex"), sample)
    call_count = :counters.new(1, [:atomics])
    oauth_path = Path.join(dir, "credentials/oauth.json")

    assert :ok =
             MingaAgent.OAuth.write_oauth_file(
               %{
                 access: "fixture-access",
                 refresh: "fixture-refresh",
                 account_id: "fixture-account",
                 expires: System.system_time(:millisecond) + 3_600_000
               },
               oauth_path
             )

    credential_opts = [
      config_dir: Path.join(dir, "credentials"),
      env: %{},
      oauth_path: oauth_path
    ]

    resolver_opts =
      MingaAgent.Test.ModelSelectionFixture.resolver_opts(model_id: "gpt-6.1-sol")
      |> Keyword.delete(:credential_snapshot)

    client = fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            StreamChunk.tool_call("find", %{"pattern" => "*.ex", "path" => "."}, %{
              id: "tc_find_without_project",
              index: 0
            }),
            StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [StreamChunk.text("done"), StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks, %{total_cost: 0.001})
    end

    File.cd!(cwd, fn ->
      :ok = Minga.Project.close()
      assert Minga.Project.resolve_root() == nil

      session =
        start_test_session(
          provider: Native,
          model_name: "openai:gpt-6.1-sol",
          credentials_snapshot_fn: fn -> MingaAgent.Credentials.snapshot(credential_opts) end,
          provider_opts: [
            model: "openai:gpt-6.1-sol",
            model_resolver_opts: resolver_opts,
            credential_opts: credential_opts,
            project_root: nil,
            tools: nil,
            llm_client: client,
            process_backend: RecordingProcessBackend,
            config: agent_config(compaction_threshold: nil, tool_approval: :none)
          ]
        )

      assert :ok = Session.subscribe(session)

      view = Native.project_view(Session.get_provider(session))
      working_dir = ProjectView.working_dir(view)
      refute working_dir == cwd
      refute File.exists?(Path.join(working_dir, "sample.ex"))

      assert :ok = Session.send_prompt(session, "Find Elixir files")
      assert_receive {:agent_event, ^session, {:status_changed, :idle}}, 10_000
      messages = Session.messages(session)

      assert {:tool_call,
              %ToolCall{
                id: "tc_find_without_project",
                name: "find",
                status: :denied,
                result: result
              }} = List.keyfind(messages, :tool_call, 0)

      assert result == "Minga has no folder to work in. Open a file or a folder."
      refute result =~ "sample.ex"
      assert {:assistant, "done"} in messages
      assert File.read!(Path.join(cwd, "sample.ex")) == sample
    end)
  end
end
