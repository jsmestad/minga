defmodule MingaEditor.Integration.AgentWorkflowConformanceTest do
  use Minga.Test.EditorCase, async: false

  alias Minga.RenderModel.UI.AgentChat
  alias Minga.Test.AgentWorkflowDriver, as: Workflow
  alias Minga.Test.ScriptedProvider
  alias Minga.Config.Options
  alias MingaAgent.Event
  alias MingaAgent.Session
  alias MingaEditor.State.AgentAccess

  @moduletag :tmp_dir
  @event_timeout 1_000

  setup do
    options_server = start_supervised!({Options, name: nil})
    assert {:ok, "test:scripted"} = Options.set(options_server, :agent_model, "test:scripted")

    %{options_server: options_server}
  end

  test "agent view opens through key input with isolated injected config", %{
    tmp_dir: dir,
    options_server: options_server
  } do
    ctx = start_agent_editor(dir, options_server)
    state = Workflow.open_agent_view(ctx)
    panel = AgentAccess.panel(state)

    assert state.workspace.keymap_scope == :agent
    assert panel.model_name == "test:scripted"
    assert panel.provider_name == "test"
    assert %AgentChat{visible?: true} = Workflow.chat_model(state)
  end

  test "scripted turn reaches the visible agent chat render model", %{
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
        "expected scripted agent turn to render thinking, highlighted assistant text, and highlighted tool output"
      )

    assert %AgentChat{visible?: true, status: :idle} = model
  end

  test "ctrl-c aborts an in-flight scripted turn through the provider seam", %{
    tmp_dir: dir,
    options_server: options_server
  } do
    script = [
      {:event, %Event.AgentStart{}},
      {:event, %Event.ThinkingDelta{delta: "still running"}},
      :wait_for_abort
    ]

    ctx = start_agent_editor(dir, options_server, script)
    Workflow.open_agent_view(ctx)
    Workflow.submit_prompt(ctx, "start a long response")

    assert_receive {:scripted_provider_prompt, _provider, "start a long response"}, @event_timeout

    wait_until(
      ctx,
      fn state ->
        state.workspace.keymap_scope == :agent and
          AgentAccess.agent(state).runtime.status == :thinking
      end,
      message: "expected the editor to show an active agent turn before interrupting"
    )

    Workflow.interrupt_turn(ctx)

    assert_receive {:scripted_provider_abort, _provider}, @event_timeout

    Workflow.wait_for_chat_model(
      ctx,
      &aborted_rendered?/1,
      "expected interrupted turn to return to idle and render the aborted system message"
    )
  end

  test "provider errors render through the visible agent chat model", %{
    tmp_dir: dir,
    options_server: options_server
  } do
    script = [
      {:event, %Event.AgentStart{}},
      {:event, %Event.Error{message: "provider exploded", kind: :unknown, provider: "test"}}
    ]

    ctx = start_agent_editor(dir, options_server, script)
    Workflow.open_agent_view(ctx)
    Workflow.submit_prompt(ctx, "trigger an error")

    assert_receive {:scripted_provider_prompt, _provider, "trigger an error"}, @event_timeout

    model =
      Workflow.wait_for_chat_model(
        ctx,
        &error_rendered?/1,
        "expected provider error to return to the visible agent chat transcript"
      )

    assert %AgentChat{visible?: true, status: :error} = model
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

  test "trusted tool approval auto-approves the next matching tool in the turn", %{
    tmp_dir: dir,
    options_server: options_server
  } do
    script = [
      {:event, %Event.AgentStart{}},
      {:event,
       %Event.ToolStart{
         tool_call_id: "tc_first",
         name: "shell",
         args: %{"command" => "mix test"}
       }},
      {:event,
       %Event.ToolApproval{
         tool_call_id: "tc_first",
         name: "shell",
         args: %{"command" => "mix test"},
         reply_to: self()
       }},
      :wait_for_continue,
      {:event,
       %Event.ToolStart{
         tool_call_id: "tc_second",
         name: "shell",
         args: %{"command" => "mix test"}
       }},
      {:event,
       %Event.ToolApproval{
         tool_call_id: "tc_second",
         name: "shell",
         args: %{"command" => "mix test"},
         reply_to: self()
       }},
      {:event, %Event.AgentEnd{usage: nil}}
    ]

    ctx = start_agent_editor(dir, options_server, script)
    Workflow.open_agent_view(ctx)
    Workflow.submit_prompt(ctx, "run trusted tools")

    assert_receive {:scripted_provider_prompt, provider, "run trusted tools"}, @event_timeout

    Workflow.wait_for_chat_model(
      ctx,
      &approval_rendered?(&1, "tc_first"),
      "expected first tool approval to become visible"
    )

    Workflow.trust_tool_turn(ctx)

    assert_receive {:tool_approval_response, "tc_first", :approve}, @event_timeout

    ScriptedProvider.continue(provider)

    assert_receive {:tool_approval_response, "tc_second", :approve}, @event_timeout

    Workflow.wait_for_chat_model(
      ctx,
      &auto_approved_tool_rendered?/1,
      "expected second matching tool approval to be auto-approved without another approval prompt"
    )
  end

  test "ctrl-enter queues a follow-up during an active turn", %{
    tmp_dir: dir,
    options_server: options_server
  } do
    script = [
      {:event, %Event.AgentStart{}},
      {:event, %Event.ThinkingDelta{delta: "still working"}},
      :wait_for_abort
    ]

    ctx = start_agent_editor(dir, options_server, script)
    Workflow.open_agent_view(ctx)
    Workflow.submit_prompt(ctx, "start a long task")

    assert_receive {:scripted_provider_prompt, _provider, "start a long task"}, @event_timeout

    wait_until(
      ctx,
      fn state -> AgentAccess.agent(state).runtime.status == :thinking end,
      message: "expected the first turn to be active before queuing a follow-up"
    )

    state = Workflow.queue_follow_up(ctx, "do this next")
    session = AgentAccess.session(state)

    assert {[], ["do this next"]} = Session.get_queued_messages(session)

    model =
      Workflow.wait_for_chat_model(
        ctx,
        &follow_up_prompt_cleared?/1,
        "expected queued follow-up to clear the prompt"
      )

    assert %AgentChat{prompt: ""} = model
  end

  test "queued follow-up is sent as the next provider turn after agent end", %{
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
        "expected queued follow-up to send as the next provider turn and render its response"
      )

    assert %AgentChat{visible?: true, status: :idle} = model
  end

  test "provider error restores queued follow-up to the prompt", %{
    tmp_dir: dir,
    options_server: options_server
  } do
    scripts = [
      [
        {:event, %Event.AgentStart{}},
        {:event, %Event.ThinkingDelta{delta: "first turn"}},
        :wait_for_continue,
        {:event, %Event.Error{message: "provider exploded", kind: :unknown, provider: "test"}}
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

    Workflow.wait_for_chat_model(
      ctx,
      &error_rendered?/1,
      "expected provider error to return to the visible agent chat transcript"
    )

    state =
      wait_until(
        ctx,
        fn state ->
          Workflow.chat_model(state).prompt == "do this next" and
            Session.get_queued_messages(session) == {[], []}
        end,
        message: "expected queued follow-up to be restored to the prompt after provider error"
      )

    assert %AgentChat{prompt: "do this next"} = Workflow.chat_model(state)
  end

  test "provider crash does not take down the agent session", %{
    tmp_dir: dir,
    options_server: options_server
  } do
    script = [
      {:event, %Event.AgentStart{}},
      :crash
    ]

    ctx = start_agent_editor(dir, options_server, script)
    state = Workflow.open_agent_view(ctx)
    session = AgentAccess.session(state)
    session_ref = Process.monitor(session)

    Workflow.submit_prompt(ctx, "trigger provider crash")

    assert_receive {:scripted_provider_prompt, _provider, "trigger provider crash"},
                   @event_timeout

    Workflow.wait_for_chat_model(
      ctx,
      &provider_crash_rendered?/1,
      "expected provider crash to leave the agent session visible in an error state"
    )

    refute_receive {:DOWN, ^session_ref, :process, ^session, _reason}, 50
    Process.demonitor(session_ref, [:flush])
  end

  defp start_agent_editor(project_root, options_server, script_or_opts \\ [])

  defp start_agent_editor(project_root, options_server, opts) when is_list(opts) do
    provider_opts =
      case Keyword.fetch(opts, :scripts) do
        {:ok, scripts} -> ScriptedProvider.scripts(scripts)
        :error -> ScriptedProvider.script(opts)
      end

    start_editor("fixture",
      project_root: project_root,
      options_server: options_server,
      agent_provider_module: ScriptedProvider,
      agent_provider_opts: provider_opts
    )
  end

  defp turn_rendered?(%AgentChat{} = model) do
    model.visible? and model.status == :idle and user_rendered?(model.messages) and
      thinking_rendered?(model.messages) and assistant_rendered?(model.messages) and
      tool_rendered?(model.messages)
  end

  defp aborted_rendered?(%AgentChat{} = model) do
    model.visible? and model.status == :idle and
      Enum.any?(model.messages, &match?({_, {:system, "Aborted", :info}}, &1))
  end

  defp error_rendered?(%AgentChat{} = model) do
    model.visible? and model.status == :error and
      Enum.any?(model.messages, &match?({_, {:system, "provider exploded", :error}}, &1))
  end

  defp approval_rendered?(%AgentChat{} = model, tool_call_id) do
    model.visible? and
      Enum.any?(
        model.messages,
        fn
          {_, {:approval_tool_call, %{name: "shell", tool_call_id: ^tool_call_id}}} -> true
          _message -> false
        end
      )
  end

  defp auto_approved_tool_rendered?(%AgentChat{} = model) do
    model.visible? and model.status == :idle and
      not Enum.any?(model.messages, &match?({_, {:approval_tool_call, _approval}}, &1)) and
      Enum.any?(
        model.messages,
        fn
          {_, {:tool_call, %{name: "shell", auto_approved_scope: :turn}}} ->
            true

          {_, {:styled_tool_call, %{name: "shell", auto_approved_scope: :turn}, _}} ->
            true

          _message ->
            false
        end
      )
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

  defp follow_up_prompt_cleared?(%AgentChat{} = model) do
    model.visible? and model.status == :thinking and model.prompt == ""
  end

  defp follow_up_turn_rendered?(%AgentChat{} = model) do
    model.visible? and model.status == :idle and
      Enum.any?(model.messages, &match?({_, {:user, "do this next"}}, &1)) and
      Enum.any?(model.messages, &match?({_, {:styled_assistant, _}}, &1))
  end

  defp provider_crash_rendered?(%AgentChat{} = model) do
    model.visible? and model.status == :error
  end

  defp user_rendered?(messages) do
    Enum.any?(messages, &match?({_, {:user, "verify the agent workflow"}}, &1))
  end

  defp thinking_rendered?(messages) do
    Enum.any?(messages, &match?({_, {:thinking, "inspect the workflow", true}}, &1))
  end

  defp assistant_rendered?(messages) do
    Enum.any?(messages, &match?({_, {:styled_assistant, _}}, &1))
  end

  defp tool_rendered?(messages) do
    Enum.any?(
      messages,
      &match?({_, {:styled_tool_call, %{name: "shell", result: "97 passed"}, _}}, &1)
    )
  end
end
