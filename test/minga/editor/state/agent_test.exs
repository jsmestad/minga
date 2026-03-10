defmodule Minga.Editor.State.AgentTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Editor.State.Agent, as: AgentState

  defp new_agent, do: %AgentState{}

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
    test "set_session stores pid and sets status to :idle" do
      pid = spawn(fn -> :ok end)
      agent = new_agent() |> AgentState.set_session(pid)
      assert agent.session == pid
      assert agent.status == :idle
    end

    test "clear_session nils the session and resets status to :idle" do
      pid = spawn(fn -> :ok end)

      agent =
        new_agent()
        |> AgentState.set_session(pid)
        |> AgentState.set_status(:thinking)
        |> AgentState.clear_session()

      assert agent.session == nil
      assert agent.status == :idle
    end
  end

  describe "panel delegation" do
    test "focus_input updates the panel's input_focused flag" do
      agent = new_agent() |> AgentState.focus_input(true)
      assert agent.panel.input_focused
    end

    test "scroll_to_bottom pins to bottom" do
      agent = new_agent() |> AgentState.scroll_down(5) |> AgentState.scroll_to_bottom()
      assert agent.panel.scroll.pinned
    end

    test "scroll_up and scroll_down adjust offset" do
      agent = new_agent() |> AgentState.scroll_down(20) |> AgentState.scroll_up(5)
      assert agent.panel.scroll.offset == 15
    end

    test "tick_spinner advances the spinner frame" do
      agent = new_agent() |> AgentState.tick_spinner() |> AgentState.tick_spinner()
      assert agent.panel.spinner_frame == 2
    end

    test "insert_char and delete_char modify input text" do
      agent =
        new_agent()
        |> AgentState.insert_char("h")
        |> AgentState.insert_char("i")
        |> AgentState.delete_char()

      assert PanelState.input_text(agent.panel) == "h"
    end

    test "clear_input_and_scroll empties input and pins to bottom" do
      agent =
        new_agent()
        |> AgentState.insert_char("hello")
        |> AgentState.clear_input_and_scroll()

      assert PanelState.input_text(agent.panel) == ""
      assert agent.panel.scroll.pinned
    end

    test "toggle_panel flips visibility" do
      agent = new_agent() |> AgentState.toggle_panel()
      assert agent.panel.visible
    end
  end

  describe "panel config" do
    test "set_thinking_level updates the panel's thinking_level" do
      agent = new_agent() |> AgentState.set_thinking_level("high")
      assert agent.panel.thinking_level == "high"
    end

    test "set_provider_name updates the panel's provider_name" do
      agent = new_agent() |> AgentState.set_provider_name("openai")
      assert agent.panel.provider_name == "openai"
    end

    test "set_model_name updates the panel's model_name" do
      agent = new_agent() |> AgentState.set_model_name("gpt-4o")
      assert agent.panel.model_name == "gpt-4o"
    end
  end

  describe "queries" do
    test "visible? reflects panel visibility" do
      refute AgentState.visible?(new_agent())
      assert new_agent() |> AgentState.toggle_panel() |> AgentState.visible?()
    end

    test "input_focused? reflects panel focus" do
      refute AgentState.input_focused?(new_agent())
      assert new_agent() |> AgentState.focus_input(true) |> AgentState.input_focused?()
    end

    test "busy? is true for :thinking and :tool_executing" do
      assert new_agent() |> AgentState.set_status(:thinking) |> AgentState.busy?()
      assert new_agent() |> AgentState.set_status(:tool_executing) |> AgentState.busy?()
      refute new_agent() |> AgentState.set_status(:idle) |> AgentState.busy?()
      refute AgentState.busy?(new_agent())
    end
  end

  describe "session history" do
    test "set_session archives previous session in history" do
      pid1 = spawn(fn -> :ok end)
      pid2 = spawn(fn -> :ok end)

      agent =
        new_agent()
        |> AgentState.set_session(pid1)
        |> AgentState.set_session(pid2)

      assert agent.session == pid2
      assert pid1 in agent.session_history
    end

    test "set_session with nil current does not add nil to history" do
      pid = spawn(fn -> :ok end)
      agent = new_agent() |> AgentState.set_session(pid)
      assert agent.session_history == []
    end

    test "all_sessions returns active + history" do
      pid1 = spawn(fn -> :ok end)
      pid2 = spawn(fn -> :ok end)

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
      pid1 = spawn(fn -> :ok end)
      pid2 = spawn(fn -> :ok end)

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
      pid = spawn(fn -> :ok end)
      agent = %AgentState{session: nil, session_history: [pid]}
      agent = AgentState.switch_session(agent, pid)
      assert agent.session == pid
      assert agent.session_history == []
    end
  end
end
