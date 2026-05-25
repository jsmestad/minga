defmodule MingaAgent.Tools.SubagentReceiveLoopTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.Subagent

  setup do
    fake_session = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(fake_session, :kill) end)
    %{fake_session: fake_session}
  end

  test "accumulates multiple text deltas and returns concatenated text on idle", %{
    fake_session: fake_session
  } do
    task = Task.async(fn -> Subagent.collect_response(fake_session) end)

    send(task.pid, {:agent_event, fake_session, {:text_delta, "hello"}})
    send(task.pid, {:agent_event, fake_session, {:text_delta, " "}})
    send(task.pid, {:agent_event, fake_session, {:text_delta, "world"}})
    send(task.pid, {:agent_event, fake_session, {:status_changed, :idle}})

    assert {:ok, "hello world"} = Task.await(task)
  end

  test "returns placeholder message when idle arrives with no prior deltas", %{
    fake_session: fake_session
  } do
    task = Task.async(fn -> Subagent.collect_response(fake_session) end)

    send(task.pid, {:agent_event, fake_session, {:status_changed, :idle}})

    assert {:ok, "(subagent completed with no text output)"} = Task.await(task)
  end

  test "returns error tuple when error event arrives", %{fake_session: fake_session} do
    task = Task.async(fn -> Subagent.collect_response(fake_session) end)

    send(task.pid, {:agent_event, fake_session, {:text_delta, "partial"}})
    send(task.pid, {:agent_event, fake_session, {:error, "something broke"}})

    assert {:error, "Subagent error: something broke"} = Task.await(task)
  end

  test "ignores non-text events without affecting accumulated text", %{
    fake_session: fake_session
  } do
    task = Task.async(fn -> Subagent.collect_response(fake_session) end)

    send(task.pid, {:agent_event, fake_session, {:tool_start, %{}}})
    send(task.pid, {:agent_event, fake_session, {:text_delta, "result"}})
    send(task.pid, {:agent_event, fake_session, {:thinking, "hmm"}})
    send(task.pid, {:agent_event, fake_session, {:unknown_event_type, :data}})
    send(task.pid, {:agent_event, fake_session, {:status_changed, :idle}})

    assert {:ok, "result"} = Task.await(task)
  end

  test "returns timeout error when no terminal event arrives within the timeout", %{
    fake_session: fake_session
  } do
    task = Task.async(fn -> Subagent.collect_response_loop(fake_session, "", 100) end)

    assert {:error, "Subagent timed out after 300 seconds"} = Task.await(task, 1_000)
  end
end
