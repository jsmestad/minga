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

      ctx = %Context{
        port_manager: self(),
        capabilities: nil,
        theme: nil,
        font_registry: nil,
        windows: nil,
        layout: nil,
        shell: MingaEditor.Shell.Traditional,
        shell_state: %{agent: %{runtime: %{status: :tool_executing}, pending_approval: :approval}},
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
        %{
          agent: AgentState.set_pending_approval(%AgentState{}, approval),
          workspace: %{agent_ui: UIState.new()}
        }
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
        shell_state: %{agent: AgentAccess.agent(state)},
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
