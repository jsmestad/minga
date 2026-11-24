defmodule MingaEditor.Agent.WorkspaceStatusTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Question
  alias MingaAgent.Question.Target, as: QuestionTarget
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target, as: ApprovalTarget
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.StartRequest
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.WorkspaceStatus
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Workspace

  describe "resolve/3" do
    test "derives one status for every workspace shape" do
      failed_ui =
        UIState.fail_start(UIState.new(), StartFailure.timed_out(StartRequest.default()))

      ui = UIState.new()

      attached = Workspace.new_agent(1, "Agent", self()) |> Workspace.set_agent_status(:idle)
      unattached = Workspace.new_agent(2, "Agent") |> Workspace.set_agent_status(:error)

      remote =
        Workspace.new_agent(3, "Agent")
        |> Workspace.put_remote_session("server", "remote-session", :connected, 0)
        |> Workspace.set_agent_status(:idle)

      background =
        Workspace.new_agent(4, "Agent", self()) |> Workspace.set_agent_status(:thinking)

      manual = Workspace.new_manual(nil)

      errored = AgentState.set_status(%AgentState{}, :error)
      working = AgentState.set_status(%AgentState{}, :tool_executing)

      cases = [
        {"failed start on the active workspace", attached, errored, failed_ui, :needs_you},
        {"failed start on a background workspace", background, nil, failed_ui, :needs_you},
        {"active attached workspace follows the live error", attached, errored, ui, :error},
        {"active attached workspace follows live work", attached, working, ui, :tool_executing},
        {"active attached workspace with a pending approval", attached, approval_waiting(), ui,
         :approval_waiting},
        {"active attached workspace with a pending question", attached, question_pending(), ui,
         :needs_you},
        {"active remote workspace follows the live error", remote, errored, ui, :error},
        {"active workspace without a Session keeps its stored status", unattached, working, ui,
         :error},
        {"background workspace keeps its stored status", background, nil, ui, :thinking},
        {"manual workspace follows the live cache", manual, errored, ui, :error},
        {"no workspace follows the live cache", nil, errored, ui, :error},
        {"no workspace and no live cache is idle", nil, nil, ui, :idle}
      ]

      for {name, workspace, live, ui, expected} <- cases do
        assert WorkspaceStatus.resolve(workspace, live, ui) == expected, name
      end
    end
  end

  defp approval_waiting do
    approval =
      Public.new(
        ApprovalTarget.new("status-fixture", "request", "tool-call"),
        "shell",
        %{},
        Preview.new(:args, "", [])
      )

    %AgentState{}
    |> AgentState.set_status(:tool_executing)
    |> AgentState.set_pending_approval(PendingApproval.new(self(), approval))
  end

  defp question_pending do
    {:ok, question} = Question.new("Which file?", ["a.ex", "b.ex"])

    target = %QuestionTarget{
      session_id: "status-fixture",
      request_id: "request",
      checkpoint_id: "checkpoint",
      tool_call_id: "tool-call"
    }

    %AgentState{}
    |> AgentState.set_status(:thinking)
    |> AgentState.project_question(self(), {target, question})
  end
end
