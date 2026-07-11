defmodule MingaEditor.Integration.AgentWorkflowConformanceTest do
  # The editor harness mutates the global SessionManager and injected Options server.
  use Minga.Test.EditorCase, async: false

  alias Minga.RenderModel.UI.AgentChat
  alias Minga.Test.AgentWorkflowDriver, as: Workflow
  alias Minga.Test.ScriptedProvider
  alias Minga.Config.Options
  alias MingaAgent.Event
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaEditor.State.AgentAccess

  @moduletag :tmp_dir
  @event_timeout 1_000

  setup do
    options_server = start_supervised!({Options, name: nil})
    assert {:ok, "test:scripted"} = Options.set(options_server, :agent_model, "test:scripted")

    %{options_server: options_server}
  end

  test "scripted prompt reaches the visible agent chat render model", %{
    tmp_dir: dir,
    options_server: options_server
  } do
    script = [
      {:event, %Event.AgentStart{}},
      {:event, %Event.ThinkingDelta{delta: "inspect the workflow"}},
      {:event, %Event.TextDelta{delta: "Here is the result:\n```elixir\n:ok\n```"}},
      {:event,
       %Event.ToolStart{tool_call_id: "tc_1", name: "shell", args: %{"command" => "mix test"}}},
      {:event, %Event.ToolEnd{tool_call_id: "tc_1", name: "shell", result: "97 passed"}},
      {:event, %Event.AgentEnd{usage: nil}}
    ]

    ctx = start_agent_editor(dir, options_server, script)
    Workflow.open_agent_view(ctx)
    Workflow.submit_prompt(ctx, "verify the agent workflow")

    assert_receive {:scripted_provider_prompt, _provider, "verify the agent workflow"},
                   @event_timeout

    model =
      Workflow.wait_for_chat_model(
        ctx,
        &turn_rendered?/1,
        "expected scripted agent turn to render thinking, assistant text, and tool output"
      )

    assert %AgentChat{visible?: true, status: :idle} = model
  end

  test "pressing Esc denies a visible tool approval through public agent input", %{
    tmp_dir: dir,
    options_server: options_server
  } do
    script = [
      {:event, %Event.AgentStart{}},
      {:event,
       %Event.ToolStart{
         tool_call_id: "tc_deny",
         name: "shell",
         args: %{"command" => "rm -rf tmp/build"}
       }},
      {:event,
       %Event.ToolApproval{
         tool_call_id: "tc_deny",
         name: "shell",
         args: %{"command" => "rm -rf tmp/build"},
         reply_to: self()
       }}
    ]

    ctx = start_agent_editor(dir, options_server, script)
    Workflow.open_agent_view(ctx)
    Workflow.submit_prompt(ctx, "try a destructive command")

    assert_receive {:scripted_provider_prompt, _provider, "try a destructive command"},
                   @event_timeout

    Workflow.wait_for_chat_model(
      ctx,
      &approval_rendered?(&1, "tc_deny"),
      "expected destructive tool approval to become visible"
    )

    send_key_sync(ctx, 27)

    assert_receive {:tool_approval_response, "tc_deny", :reject}, @event_timeout

    Workflow.wait_for_chat_model(
      ctx,
      &approval_denial_rendered?/1,
      "expected denied tool approval to clear and add a transcript note"
    )
  end

  test "queued follow-up is the next provider turn and is visible", %{
    tmp_dir: dir,
    options_server: options_server
  } do
    scripts = [
      [
        {:event, %Event.AgentStart{}},
        {:event, %Event.ThinkingDelta{delta: "first turn"}},
        :wait_for_continue,
        {:event, %Event.AgentEnd{usage: nil}}
      ],
      [
        {:event, %Event.AgentStart{}},
        {:event, %Event.TextDelta{delta: "second turn response"}},
        {:event, %Event.AgentEnd{usage: nil}}
      ]
    ]

    ctx = start_agent_editor(dir, options_server, scripts: scripts)
    Workflow.open_agent_view(ctx)
    Workflow.submit_prompt(ctx, "start a long task")

    assert_receive {:scripted_provider_prompt, provider, "start a long task"}, @event_timeout

    wait_until(
      ctx,
      fn state -> AgentAccess.agent(state).runtime.status == :thinking end,
      message: "expected the first turn to be active before queuing a follow-up"
    )

    state = Workflow.queue_follow_up(ctx, "do this next")
    session = AgentAccess.session(state)
    assert {[], ["do this next"]} = Session.get_queued_messages(session)

    ScriptedProvider.continue(provider)

    assert_receive {:scripted_provider_prompt, ^provider, "do this next"}, @event_timeout
    assert {[], []} = Session.get_queued_messages(session)

    model =
      Workflow.wait_for_chat_model(
        ctx,
        &follow_up_turn_rendered?/1,
        "expected queued follow-up to render the next provider turn"
      )

    assert %AgentChat{visible?: true, status: :idle} = model
  end

  defp start_agent_editor(project_root, options_server, opts) when is_list(opts) do
    sessions_before =
      MapSet.new(
        SessionManager.list_sessions()
        |> Enum.map(fn {_id, pid, _meta} -> pid end)
      )

    provider_opts =
      case Keyword.fetch(opts, :scripts) do
        {:ok, scripts} -> ScriptedProvider.scripts(scripts)
        :error -> ScriptedProvider.script(opts)
      end

    ctx =
      start_editor("fixture",
        project_root: project_root,
        options_server: options_server,
        agent_provider_module: ScriptedProvider,
        agent_provider_opts: provider_opts
      )

    on_exit(fn ->
      for {_id, pid, _meta} <- SessionManager.list_sessions(),
          not MapSet.member?(sessions_before, pid) do
        SessionManager.stop_session_by_pid(pid)
      end
    end)

    ctx
  end

  defp turn_rendered?(%AgentChat{} = model) do
    model.visible? and model.status == :idle and user_rendered?(model.messages) and
      thinking_rendered?(model.messages) and assistant_rendered?(model.messages) and
      tool_rendered?(model.messages)
  end

  defp approval_rendered?(%AgentChat{} = model, tool_call_id) do
    model.visible? and
      Enum.any?(model.messages, fn
        {_, {:approval_tool_call, %{name: "shell", tool_call_id: ^tool_call_id}}} -> true
        _message -> false
      end)
  end

  defp approval_denial_rendered?(%AgentChat{} = model) do
    model.visible? and
      not Enum.any?(model.messages, &match?({_, {:approval_tool_call, _approval}}, &1)) and
      Enum.any?(
        model.messages,
        &match?(
          {_, {:system, "Denied shell: the tool was refused and the agent was notified.", :info}},
          &1
        )
      )
  end

  defp follow_up_turn_rendered?(%AgentChat{} = model) do
    model.visible? and model.status == :idle and
      Enum.any?(model.messages, &match?({_, {:user, "do this next"}}, &1)) and
      assistant_rendered?(model.messages)
  end

  defp user_rendered?(messages) do
    Enum.any?(messages, &match?({_, {:user, "verify the agent workflow"}}, &1))
  end

  defp thinking_rendered?(messages) do
    Enum.any?(messages, &match?({_, {:thinking, "inspect the workflow", true}}, &1))
  end

  defp assistant_rendered?(messages) do
    Enum.any?(messages, fn
      {_, {:styled_assistant, _}} -> true
      {_, {:assistant_markdown, _}} -> true
      _message -> false
    end)
  end

  defp tool_rendered?(messages) do
    Enum.any?(
      messages,
      &match?({_, {:styled_tool_call, %{name: "shell", result: "97 passed"}, _}}, &1)
    )
  end
end
