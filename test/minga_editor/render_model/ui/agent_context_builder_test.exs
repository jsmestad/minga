defmodule MingaEditor.RenderModel.UI.AgentContextBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.AgentContext
  alias Minga.RenderModel.UI.AgentContext.Todo
  alias MingaAgent.TodoItem
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.Events, as: AgentEvents
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.AgentContextBuilder
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Agent, as: AgentState

  describe "build/1" do
    test "projects activity, todos, and review vocabulary into agent context" do
      todo = %TodoItem{id: "1", description: "Run tests", status: :in_progress}

      activity =
        Activity.new()
        |> Activity.set_todos([todo])
        |> Activity.start_turn(~U[2026-06-23 12:00:00Z])
        |> Activity.start_tool("shell")
        |> Activity.record_file("lib/a.ex")

      agent_ui = UIState.replace_activity(UIState.new(), activity)

      agent =
        %AgentState{}
        |> AgentState.set_status(:tool_executing)
        |> AgentState.set_pending_approval(%{tool_call_id: "tc", name: "shell", args: %{}})

      ctx =
        context(
          agent_ui,
          TraditionalState.replace_agent(%TraditionalState{}, agent)
        )

      assert %AgentContext{
               visible: true,
               task: "Running shell",
               status: :needs_you,
               can_approve: true,
               todos: [%Todo{description: "Run tests", status: :in_progress}],
               progress: %{
                 active_action: "Running shell",
                 tool_count: 1,
                 file_count: 1,
                 review_hint: "Review: approve or reject changes"
               }
             } = AgentContextBuilder.build(ctx)
    end

    test "approval-only visible context keeps the dispatch timestamp stable" do
      approval = %{tool_call_id: "tc-approval", name: "shell", args: %{}}

      state =
        TestHelpers.base_state(backend: :gui)
        |> MingaEditor.Shell.Traditional.Workflow.install_agent_state(
          AgentState.set_pending_approval(%AgentState{}, approval)
        )
        |> then(&AgentEvents.dispatch(&1, {:approval_pending, approval}))

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
