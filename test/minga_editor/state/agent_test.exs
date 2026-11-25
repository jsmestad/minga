defmodule MingaEditor.State.AgentTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.RuntimeState
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.State.Agent, as: AgentState

  defp new_agent do
    {:ok, _prompt_buf} = BufferProcess.start_link(content: "")
    %AgentState{}
  end

  describe "status" do
    test "set_status updates the status field" do
      agent = new_agent() |> AgentState.set_status(:thinking)
      assert agent.runtime.status == :thinking
    end

    test "set_status clears active_tool_name when leaving tool execution" do
      agent =
        new_agent()
        |> AgentState.set_active_tool_name("read_file")
        |> AgentState.set_status(:idle)

      assert agent.runtime.status == :idle
      assert agent.runtime.active_tool_name == nil

      agent =
        new_agent()
        |> AgentState.set_active_tool_name("read_file")
        |> AgentState.set_status(:error)

      assert agent.runtime.status == :error
      assert agent.runtime.active_tool_name == nil
    end

    test "set_status preserves active_tool_name while still tool executing" do
      agent =
        new_agent()
        |> AgentState.set_active_tool_name("read_file")
        |> AgentState.set_status(:tool_executing)

      assert agent.runtime.status == :tool_executing
      assert agent.runtime.active_tool_name == "read_file"
    end

    test "set_error sets status to :error and stores the message" do
      agent = new_agent() |> AgentState.set_error("something broke")
      assert agent.runtime.status == :error
      assert agent.error == "something broke"
    end
  end

  describe "session snapshots" do
    test "apply_session_snapshot sets active_tool_name only while tool executing" do
      agent =
        new_agent()
        |> AgentState.apply_session_snapshot(self(), :tool_executing, nil, nil, "read_file")

      assert agent.runtime.status == :tool_executing
      assert agent.runtime.active_tool_name == "read_file"

      agent = AgentState.apply_session_snapshot(agent, self(), :idle, nil, nil, "stale_tool")

      assert agent.runtime.status == :idle
      assert agent.runtime.active_tool_name == nil
    end

    test "a snapshot binds the cache to its Session, and a reset presents none" do
      assert AgentState.session(new_agent()) == nil

      agent = AgentState.apply_session_snapshot(new_agent(), self(), :thinking, nil, nil, nil)
      assert AgentState.session(agent) == self()

      # Status events keep the binding; only a reset drops it.
      assert agent |> AgentState.set_status(:idle) |> AgentState.session() == self()
      assert agent |> AgentState.reset_cache() |> AgentState.session() == nil
    end

    test "a replaced Session carries the cache over only when the cache presents the old one" do
      old = spawn_link(fn -> Process.sleep(:infinity) end)
      new = spawn_link(fn -> Process.sleep(:infinity) end)
      bound = AgentState.apply_session_snapshot(new_agent(), old, :thinking, nil, nil, nil)

      assert bound |> AgentState.session_replaced(old, new) |> AgentState.session() == new
      assert bound |> AgentState.session_replaced(self(), new) |> AgentState.session() == old
      assert new_agent() |> AgentState.session_replaced(old, new) |> AgentState.session() == nil
    end
  end

  describe "reset_cache" do
    test "reset_cache clears error, pending_approval, and resets status to :idle" do
      approval =
        Public.new(
          Target.new("state-fixture", "admitted-request", "x"),
          "shell",
          %{},
          Preview.new(:args, "", [])
        )

      binding = PendingApproval.new(self(), approval)

      agent =
        new_agent()
        |> AgentState.set_error("boom")
        |> AgentState.set_pending_approval(binding)
        |> AgentState.set_status(:thinking)
        |> AgentState.reset_cache()

      assert agent.error == nil
      assert agent.pending_approval == nil
      assert agent.runtime.status == :idle
    end

    test "reset_cache preserves runtime identity fields" do
      agent =
        %{new_agent() | runtime: RuntimeState.set_session_id(%RuntimeState{}, "session-1")}
        |> AgentState.reset_cache()

      assert agent.runtime.active_session_id == "session-1"
    end
  end

  describe "queries" do
    test "busy? is true for :thinking and :tool_executing" do
      assert new_agent() |> AgentState.set_status(:thinking) |> AgentState.busy?()
      assert new_agent() |> AgentState.set_status(:tool_executing) |> AgentState.busy?()
      refute new_agent() |> AgentState.set_status(:plan) |> AgentState.busy?()
      refute new_agent() |> AgentState.set_status(:idle) |> AgentState.busy?()
      refute AgentState.busy?(new_agent())
    end
  end
end
