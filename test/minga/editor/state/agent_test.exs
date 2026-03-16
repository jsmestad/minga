defmodule Minga.Editor.State.AgentTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State.Agent, as: AgentState

  defp new_agent do
    {:ok, _prompt_buf} = BufferServer.start_link(content: "")
    %AgentState{}
  end

  describe "status" do
    test "set_status updates the status field" do
      agent = new_agent() |> AgentState.set_status(:thinking)
      assert agent.status == :thinking
    end

    test "set_error sets status to :error and stores the message" do
      agent = new_agent() |> AgentState.set_error("something broke")
      assert agent.status == :error
      assert agent.error == "something broke"
    end
  end

  describe "session lifecycle" do
    test "set_session stores pid, monitors it, and sets status to :idle" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      agent = new_agent() |> AgentState.set_session(pid)
      assert agent.session == pid
      assert agent.status == :idle
      assert is_reference(agent.session_monitor)
    end

    test "set_session demonitors previous session when replacing" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      agent =
        new_agent()
        |> AgentState.set_session(pid1)

      old_ref = agent.session_monitor

      agent = AgentState.set_session(agent, pid2)
      assert agent.session == pid2
      assert agent.session_monitor != old_ref
      # Old monitor should be flushed; killing pid1 should not deliver :DOWN
      Process.exit(pid1, :kill)
      refute_receive {:DOWN, ^old_ref, :process, ^pid1, _}, 50
    end

    test "clear_session demonitors and nils the session" do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      agent =
        new_agent()
        |> AgentState.set_session(pid)
        |> AgentState.set_status(:thinking)

      old_ref = agent.session_monitor
      agent = AgentState.clear_session(agent)

      assert agent.session == nil
      assert agent.session_monitor == nil
      assert agent.status == :idle
      # Old monitor should be flushed
      Process.exit(pid, :kill)
      refute_receive {:DOWN, ^old_ref, :process, ^pid, _}, 50
    end

    test "monitor delivers :DOWN when session process dies" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      agent = new_agent() |> AgentState.set_session(pid)
      ref = agent.session_monitor

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500
    end
  end

  describe "queries" do
    test "busy? is true for :thinking and :tool_executing" do
      assert new_agent() |> AgentState.set_status(:thinking) |> AgentState.busy?()
      assert new_agent() |> AgentState.set_status(:tool_executing) |> AgentState.busy?()
      refute new_agent() |> AgentState.set_status(:idle) |> AgentState.busy?()
      refute AgentState.busy?(new_agent())
    end
  end

  describe "session history" do
    test "set_session archives previous session in history" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      agent =
        new_agent()
        |> AgentState.set_session(pid1)
        |> AgentState.set_session(pid2)

      assert agent.session == pid2
      assert pid1 in agent.session_history
    end

    test "set_session with nil current does not add nil to history" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      agent = new_agent() |> AgentState.set_session(pid)
      assert agent.session_history == []
    end

    test "all_sessions returns active + history" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      agent =
        new_agent()
        |> AgentState.set_session(pid1)
        |> AgentState.set_session(pid2)

      all = AgentState.all_sessions(agent)
      assert pid2 in all
      assert pid1 in all
      assert hd(all) == pid2
    end

    test "all_sessions returns empty when no session" do
      assert AgentState.all_sessions(new_agent()) == []
    end

    test "switch_session swaps active and moves old to history" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      agent =
        new_agent()
        |> AgentState.set_session(pid1)
        |> AgentState.set_session(pid2)
        |> AgentState.switch_session(pid1)

      assert agent.session == pid1
      assert pid2 in agent.session_history
      refute pid1 in agent.session_history
    end

    test "switch_session with nil current just activates from history" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      agent = %AgentState{session: nil, session_history: [pid]}
      agent = AgentState.switch_session(agent, pid)
      assert agent.session == pid
      assert agent.session_history == []
    end

    test "switch_session swaps monitors" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      agent =
        new_agent()
        |> AgentState.set_session(pid1)
        |> AgentState.set_session(pid2)

      old_ref = agent.session_monitor
      agent = AgentState.switch_session(agent, pid1)

      assert agent.session_monitor != old_ref
      assert is_reference(agent.session_monitor)
    end
  end
end
