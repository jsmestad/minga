defmodule MingaEditor.RenderModel.UI.AgentContextBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.{AgentContextEncoder, Caches}
  alias Minga.RenderModel.UI.AgentContext
  alias Minga.RenderModel.UI.AgentContext.Todo
  alias MingaAgent.TodoItem
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.Events, as: AgentEvents
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.AgentContextBuilder
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Agent, as: AgentState

  @spec approval(String.t()) :: Public.t()
  defp approval(tool_call_id) do
    Public.new(
      Target.new("context-fixture", "admitted-request", tool_call_id),
      "shell",
      %{},
      Preview.new(:args, "", [])
    )
  end

  describe "build/1" do
    test "unavailable chat does not display retained tool activity as live" do
      activity = Activity.start_tool(Activity.new(), "call-before-switch", "shell")

      ui =
        UIState.new()
        |> UIState.replace_activity(activity)
        |> UIState.transition_chat(:unavailable)

      ctx = context(ui, %TraditionalState{})

      refute AgentContextBuilder.visible?(ctx)
      assert %AgentContext{visible: false} = AgentContextBuilder.build(ctx)
    end

    test "tool approval keeps attention without offering unrelated task review actions" do
      todo = %TodoItem{id: "1", description: "Run tests", status: :in_progress}

      activity =
        Activity.new()
        |> Activity.set_todos([todo])
        |> Activity.start_turn(~U[2026-06-23 12:00:00Z])
        |> Activity.start_tool("call-1", "shell")
        |> Activity.record_file("lib/a.ex")

      agent_ui = UIState.replace_activity(UIState.new(), activity)

      agent =
        %AgentState{}
        |> AgentState.set_status(:tool_executing)
        |> AgentState.set_pending_approval(PendingApproval.new(self(), approval("tc")))

      ctx =
        context(
          agent_ui,
          TraditionalState.replace_agent(%TraditionalState{}, agent)
        )

      assert %AgentContext{
               visible: true,
               task: "Awaiting approval for shell",
               status: :needs_you,
               can_approve: false,
               todos: [%Todo{description: "Run tests", status: :in_progress}],
               progress: %{
                 active_action: "Awaiting approval for shell",
                 tool_count: 1,
                 file_count: 1,
                 review_hint: ""
               }
             } = AgentContextBuilder.build(ctx)
    end

    test "idle with unfinished activity does not imply completed work" do
      todo = %TodoItem{id: "unfinished", description: "Run verification", status: :in_progress}
      activity = Activity.set_todos(Activity.new(), [todo])
      agent_ui = UIState.replace_activity(UIState.new(), activity)
      agent = AgentState.set_status(%AgentState{}, :idle)
      ctx = context(agent_ui, TraditionalState.replace_agent(%TraditionalState{}, agent))

      assert %AgentContext{
               visible: true,
               status: :idle,
               todos: [%Todo{status: :in_progress}]
             } = AgentContextBuilder.build(ctx)
    end

    test "an error without recorded activity has no elapsed time and is sent only once" do
      agent = AgentState.set_status(%AgentState{}, :error)
      ctx = context(UIState.new(), TraditionalState.replace_agent(%TraditionalState{}, agent))

      assert %AgentContext{visible: true, status: :errored, dispatch_timestamp: nil} =
               first = AgentContextBuilder.build(ctx)

      assert {<<0x88, _size::16, 1, task_size::16, _task::binary-size(task_size), 0::64, 5,
                _rest::binary>>, caches} = AgentContextEncoder.encode(first, Caches.new())

      assert {nil, ^caches} =
               ctx |> AgentContextBuilder.build() |> AgentContextEncoder.encode(caches)
    end

    test "a failed start needs the user instead of showing an error" do
      agent = AgentState.set_status(%AgentState{}, :error)
      shell = TraditionalState.replace_agent(%TraditionalState{}, agent)
      request = MingaEditor.Agent.StartRequest.default()

      for {failure, task} <- [
            {MingaEditor.Agent.StartFailure.timed_out(request), "Agent could not start"},
            {MingaEditor.Agent.StartFailure.missing_credentials(), "Agent needs setup"}
          ] do
        ui = UIState.fail_start(UIState.new(), failure)

        assert %AgentContext{visible: true, status: :needs_you, task: ^task} =
                 AgentContextBuilder.build(context(ui, shell))
      end
    end

    test "approval-only visible context keeps the dispatch timestamp stable" do
      approval = approval("tc-approval")

      state =
        TestHelpers.base_state(backend: :gui)
        |> AgentEvents.dispatch(self(), {:approval_pending, approval})

      started_at = state.workspace.agent_ui.view.activity.started_at
      assert started_at != nil

      ctx =
        context(
          state.workspace.agent_ui,
          TraditionalState.replace_agent(
            %TraditionalState{},
            MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
          )
        )

      first = AgentContextBuilder.build(ctx)
      second = AgentContextBuilder.build(ctx)

      assert first.visible
      assert first.status == :needs_you
      assert first.dispatch_timestamp == started_at
      assert second.dispatch_timestamp == started_at
      assert first.dispatch_timestamp == second.dispatch_timestamp
    end
  end

  defp context(agent_ui, shell_state) do
    ctx =
      TestHelpers.base_state(port_manager: nil)
      |> Context.from_editor_state()

    workspace = %{ctx.workspace | agent_ui: agent_ui}
    frame = %{ctx.intent.frame | shell_state: shell_state}

    %{ctx | workspace: workspace, intent: %{ctx.intent | frame: frame, workspace: workspace}}
  end
end
