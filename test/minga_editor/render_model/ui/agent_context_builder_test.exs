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
  alias MingaEditor.State.AgentAccess

  describe "build/1" do
    test "projects activity, todos, and review vocabulary into agent context" do
      todo = %TodoItem{id: "1", description: "Run tests", status: :in_progress}

      activity =
        Activity.new()
        |> Activity.set_todos([todo])
        |> Activity.start_turn(~U[2026-06-23 12:00:00Z])
        |> Activity.start_tool("shell")
        |> Activity.record_file("lib/a.ex")

      agent_ui = UIState.update_activity(UIState.new(), fn _ -> activity end)

      agent =
        %AgentState{}
        |> AgentState.set_status(:tool_executing)
        |> AgentState.set_pending_approval(%{tool_call_id: "tc", name: "shell", args: %{}})

      ctx = %Context{
        port_manager: self(),
        capabilities: nil,
        theme: nil,
        font_registry: nil,
        windows: nil,
        layout: nil,
        shell: MingaEditor.Shell.Traditional,
        shell_state: TraditionalState.replace_agent(%TraditionalState{}, agent),
        agent_ui: agent_ui
      }

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
        TestHelpers.base_state()
        |> AgentAccess.update_agent(fn _agent ->
          AgentState.set_pending_approval(%AgentState{}, approval)
        end)
        |> then(fn state -> elem(AgentEvents.handle(state, {:approval_pending, approval}), 0) end)

      started_at = AgentAccess.view(state).activity.started_at
      assert started_at != nil

      ctx = %Context{
        port_manager: self(),
        capabilities: nil,
        theme: nil,
        font_registry: nil,
        windows: nil,
        layout: nil,
        shell: MingaEditor.Shell.Traditional,
        shell_state:
          TraditionalState.replace_agent(%TraditionalState{}, AgentAccess.agent(state)),
        agent_ui: AgentAccess.agent_ui(state)
      }

      first = AgentContextBuilder.build(ctx)
      second = AgentContextBuilder.build(ctx)

      assert first.visible
      assert first.status == :needs_you
      assert first.dispatch_timestamp == started_at
      assert second.dispatch_timestamp == started_at
      assert first.dispatch_timestamp == second.dispatch_timestamp
    end
  end
end
