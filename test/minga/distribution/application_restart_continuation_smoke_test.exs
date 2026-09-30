defmodule Minga.Distribution.ApplicationRestartContinuationSmokeTest do
  @moduledoc """
  Verifies a completed provider-native tool exchange with an inline image survives
  stopping and restarting the full Minga application on a separate BEAM node.

  Run explicitly with:

      mix test --include distributed test/minga/distribution/application_restart_continuation_smoke_test.exs
  """

  # This test boots real peer nodes and stops/restarts an application.
  use Minga.Test.DistributedCase, async: false

  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias Minga.Test.SessionContinuationProvider

  @moduletag :distributed

  setup_all do
    System.cmd("epmd", ["-daemon"])
    :ok
  end

  test "completed tool and image continuation survives a full application restart" do
    peer_name = :"minga_restart_smoke_#{System.unique_integer([:positive])}@127.0.0.1"
    {:ok, peer} = start_peer_node(peer_name)
    on_exit(fn -> stop_peer_node(peer) end)

    store_dir =
      Path.join(System.tmp_dir!(), "minga-restart-smoke-#{System.unique_integer([:positive])}")

    config_home = Path.join(store_dir, "config")
    File.mkdir_p!(Path.join(config_home, "minga"))
    on_exit(fn -> File.rm_rf(store_dir) end)

    :erpc.call(peer.node, Application, :load, [:minga])

    :ok =
      :erpc.call(peer.node, Application, :put_all_env, [[minga: Application.get_all_env(:minga)]])

    :erpc.call(
      peer.node,
      System,
      :put_env,
      [[{"XDG_CONFIG_HOME", config_home}, {"XDG_DATA_HOME", store_dir}]]
    )

    :erpc.call(peer.node, Minga.Git.Stub, :ensure_table, [])
    :erpc.call(peer.node, Minga.Tool.Installer.Stub, :ensure_table, [])
    {:ok, _started} = :erpc.call(peer.node, Application, :ensure_all_started, [:minga])

    session_opts = [
      provider: SessionContinuationProvider,
      provider_opts: [test_pid: self()],
      persist?: true,
      session_store_dir: store_dir
    ]

    {:ok, session_id, session_pid} =
      :erpc.call(peer.node, SessionManager, :start_session, [session_opts])

    :ok = Session.subscribe(session_pid, self())

    prompt = [
      ReqLLM.Message.ContentPart.text("Inspect this attachment and use the file tool."),
      ReqLLM.Message.ContentPart.image(<<0, 255, 10, 42>>, "image/png")
    ]

    assert :ok = Session.send_prompt(session_pid, prompt)
    assert_receive {:continuation_request, request}, 5_000

    assistant_tool_call = %ReqLLM.Message{
      role: :assistant,
      content: [
        ReqLLM.Message.ContentPart.provider_block(:anthropic, %{
          "type" => "server_tool_use",
          "signature" => <<9, 0, 9>>
        })
      ],
      metadata: %{response_id: "restart-smoke-response", phase: :analysis},
      tool_calls: [
        ReqLLM.ToolCall.new("restart-smoke-call", "read_file", ~s({"path":"example.txt"})),
        ReqLLM.ToolCall.new("restart-smoke-call-2", "read_file", ~s({"path":"second.txt"}))
      ],
      reasoning_details: [
        %ReqLLM.Message.ReasoningDetails{
          text: "provider-native reasoning",
          signature: <<1, 2, 255>>,
          encrypted?: true,
          provider: :anthropic,
          format: "anthropic-v1",
          index: 0,
          provider_data: %{"redacted" => <<3, 0, 4>>}
        }
      ]
    }

    tool_results = [
      %ReqLLM.Message{
        role: :tool,
        name: "read_file",
        tool_call_id: "restart-smoke-call",
        content: "durable tool result"
      },
      %ReqLLM.Message{
        role: :tool,
        name: "read_file",
        tool_call_id: "restart-smoke-call-2",
        content: "second durable tool result"
      }
    ]

    completed_messages =
      Enum.concat([
        request.messages,
        [assistant_tool_call],
        tool_results,
        [%ReqLLM.Message{role: :assistant, content: "The attachment was inspected."}]
      ])

    provider_pid = Session.get_provider(session_pid)

    assert :ok =
             SessionContinuationProvider.complete(provider_pid, request, completed_messages)

    assert_receive {:agent_event, ^session_pid, {:resumable_boundary, _revision}}, 5_000
    assert :ok = :erpc.call(peer.node, Application, :stop, [:minga])
    {:ok, _restarted} = :erpc.call(peer.node, Application, :ensure_all_started, [:minga])

    {:ok, ^session_id, restored_pid} =
      :erpc.call(peer.node, SessionManager, :start_or_get_session, [session_id, session_opts])

    assert restored_pid != session_pid
    assert :ok = Session.load_session(restored_pid, session_id)
    assert :ok = Session.send_prompt(restored_pid, "Continue after application restart.")
    assert_receive {:continuation_request, resumed_request}, 5_000

    assert resumed_request.messages ==
             Enum.concat(completed_messages, [
               ReqLLM.Context.user("Continue after application restart.")
             ])

    assert :ok = :erpc.call(peer.node, Application, :stop, [:minga])
  end
end
