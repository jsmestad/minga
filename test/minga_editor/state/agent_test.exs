defmodule MingaEditor.State.AgentTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
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
        |> AgentState.apply_session_snapshot(:tool_executing, nil, nil, "read_file")

      assert agent.runtime.status == :tool_executing
      assert agent.runtime.active_tool_name == "read_file"

      agent = AgentState.apply_session_snapshot(agent, :idle, nil, nil, "stale_tool")

      assert agent.runtime.status == :idle
      assert agent.runtime.active_tool_name == nil
    end
  end

  describe "reset_cache" do
    test "reset_cache clears error, pending_approval, and resets status to :idle" do
      agent =
        new_agent()
        |> AgentState.set_error("boom")
        |> AgentState.set_pending_approval(%{tool_call_id: "x"})
        |> AgentState.set_status(:thinking)
        |> AgentState.reset_cache()

      assert agent.error == nil
      assert agent.pending_approval == nil
      assert agent.runtime.status == :idle
    end

    test "reset_cache preserves buffer pid (rendering stays on the same buffer)" do
      buf = self()
      agent = new_agent() |> AgentState.set_buffer(buf) |> AgentState.reset_cache()
      assert agent.buffer == buf
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
