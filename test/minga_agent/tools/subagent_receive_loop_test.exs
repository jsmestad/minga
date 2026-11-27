defmodule MingaAgent.Tools.SubagentReceiveLoopTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.Subagent

  setup do
    %{fake_session: self(), handback: make_ref()}
  end

  test "accumulates multiple text deltas and returns concatenated text at handback", %{
    fake_session: fake_session,
    handback: handback
  } do
    task = Task.async(fn -> Subagent.collect_response_loop(fake_session, handback, "", 1_000) end)

    send(task.pid, {:agent_event, fake_session, {:text_delta, "hello"}})
    send(task.pid, {:agent_event, fake_session, {:text_delta, " "}})
    send(task.pid, {:agent_event, fake_session, {:text_delta, "world"}})
    send(task.pid, {:subagent_handback, fake_session, handback})

    assert {:ok, "hello world"} = Task.await(task)
  end

  test "returns placeholder message when handback has no prior deltas", %{
    fake_session: fake_session,
    handback: handback
  } do
    task = Task.async(fn -> Subagent.collect_response_loop(fake_session, handback, "", 1_000) end)

    send(task.pid, {:subagent_handback, fake_session, handback})

    assert {:ok, "(subagent completed with no text output)"} = Task.await(task)
  end

  test "returns error tuple when error event arrives", %{
    fake_session: fake_session,
    handback: handback
  } do
    task = Task.async(fn -> Subagent.collect_response_loop(fake_session, handback, "", 1_000) end)

    send(task.pid, {:agent_event, fake_session, {:text_delta, "partial"}})
    send(task.pid, {:agent_event, fake_session, {:error, "something broke"}})

    assert {:error, "Subagent error: something broke"} = Task.await(task)
  end

  test "ignores status changes and another handback without affecting accumulated text", %{
    fake_session: fake_session,
    handback: handback
  } do
    task = Task.async(fn -> Subagent.collect_response_loop(fake_session, handback, "", 1_000) end)

    send(task.pid, {:subagent_handback, fake_session, make_ref()})
    send(task.pid, {:agent_event, fake_session, {:status_changed, :idle}})
    send(task.pid, {:agent_event, fake_session, {:tool_start, %{}}})
    send(task.pid, {:agent_event, fake_session, {:text_delta, "result"}})
    send(task.pid, {:agent_event, fake_session, {:thinking, "hmm"}})
    send(task.pid, {:agent_event, fake_session, {:unknown_event_type, :data}})
    send(task.pid, {:subagent_handback, fake_session, handback})

    assert {:ok, "result"} = Task.await(task)
  end

  test "returns timeout error when no terminal event arrives within the timeout", %{
    fake_session: fake_session,
    handback: handback
  } do
    task = Task.async(fn -> Subagent.collect_response_loop(fake_session, handback, "", 100) end)

    assert {:error, "Subagent timed out after 300 seconds"} = Task.await(task, 1_000)
  end
end
