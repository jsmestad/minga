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
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
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
        {"manual workspace follows a live cache that presents no conversation", manual, errored,
         ui, :error},
        {"no workspace follows the live cache", nil, errored, ui, :error},
        {"no workspace and no live cache is idle", nil, nil, ui, :idle}
      ]

      for {name, workspace, live, ui, expected} <- cases do
        assert WorkspaceStatus.resolve(workspace, live, ui) == expected, name
      end
    end
  end

  describe "active/2 with a file in front" do
    # The cache as a conversation leaves it: bound to its Session, with the status it had then.
    defp left_working(session),
      do: AgentState.apply_session_snapshot(%AgentState{}, session, :thinking, nil, nil, nil)

    defp shell(tab_bar, %AgentState{} = live) do
      %TraditionalState{}
      |> TraditionalState.install_tab_bar(tab_bar)
      |> TraditionalState.replace_agent(live)
    end

    defp file_in_front(session) do
      {tab_bar, workspace} =
        Tab.new_file(1, "manual.ex") |> TabBar.new() |> TabBar.add_workspace("Agent", session)

      {tab_bar, workspace.id}
    end

    test "speaks the stored status of the conversation shown last, not the cache's copy of it" do
      session = self()
      {tab_bar, id} = file_in_front(session)
      ui = UIState.new()

      # What the conversation's Session reported after it left the front.
      for stored <- [:thinking, :tool_executing, :approval_waiting, :stopped, :idle, :error] do
        tab_bar = TabBar.set_workspace_agent_status(tab_bar, id, stored)

        assert WorkspaceStatus.active(shell(tab_bar, left_working(session)), ui) == stored
      end
    end

    test "a turn that starts after the conversation left the front is spoken too" do
      session = self()
      {tab_bar, id} = file_in_front(session)
      left_idle = AgentState.apply_session_snapshot(%AgentState{}, session, :idle, nil, nil, nil)
      tab_bar = TabBar.set_workspace_agent_status(tab_bar, id, :thinking)

      assert WorkspaceStatus.active(shell(tab_bar, left_idle), UIState.new()) == :thinking
    end

    test "is idle once the conversation shown last has ended" do
      session = self()
      {tab_bar, _id} = file_in_front(session)
      tab_bar = TabBar.session_ended(tab_bar, session, :idle)

      assert WorkspaceStatus.active(shell(tab_bar, left_working(session)), UIState.new()) == :idle
    end

    test "agrees with the row the Spaces bar shows for that conversation" do
      session = self()
      {tab_bar, id} = file_in_front(session)
      tab_bar = TabBar.set_workspace_agent_status(tab_bar, id, :stopped)
      live = left_working(session)
      workspace = TabBar.get_workspace(tab_bar, id)

      assert WorkspaceStatus.active(shell(tab_bar, live), UIState.new()) ==
               WorkspaceStatus.resolve_in(workspace, 0, live, UIState.new())
    end

    test "a cache that presents no conversation is the only source" do
      {tab_bar, _id} = file_in_front(self())
      unbound = AgentState.set_status(%AgentState{}, :error)

      assert WorkspaceStatus.active(shell(tab_bar, unbound), UIState.new()) == :error
      assert WorkspaceStatus.active(shell(nil, left_working(self())), UIState.new()) == :thinking
      assert WorkspaceStatus.active(:another_shell, UIState.new()) == :idle
    end

    test "a failed start in the file's own conversation needs the user" do
      {tab_bar, _id} = file_in_front(self())
      failed = UIState.fail_start(UIState.new(), StartFailure.timed_out(StartRequest.default()))

      assert WorkspaceStatus.active(shell(tab_bar, left_working(self())), failed) == :needs_you
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
