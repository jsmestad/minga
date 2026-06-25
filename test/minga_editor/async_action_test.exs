defmodule MingaEditor.AsyncActionTest do
  @moduledoc "Per-lane serial offloading of slow editor work with error capture."
  use ExUnit.Case, async: true

  alias MingaEditor.AsyncAction
  alias MingaEditor.State, as: EditorState

  @async_action_timeout 1_000

  defp state, do: %EditorState{port_manager: self(), workspace: nil}

  test "run/3 starts the work, records an in-flight token, and reports back async" do
    s = AsyncAction.run(state(), :demo, fn -> send(self(), :work_ran) end)

    lane = s.async_actions[:demo]
    assert is_reference(lane.running)
    assert lane.queue == []
    assert AsyncAction.current?(s, :demo, lane.running)
    # The work runs in a Task and reports back asynchronously, not inline.
    assert_receive {:async_action_result, :demo, _token, _result}, @async_action_timeout
  end

  test "a second op on a busy lane is queued, not started concurrently" do
    s = AsyncAction.run(state(), :demo, fn -> :first end)
    token1 = s.async_actions[:demo].running

    # Enqueue while busy: running token unchanged, queue grows, no new Task yet.
    s = AsyncAction.run(s, :demo, fn -> :second end)
    assert s.async_actions[:demo].running == token1
    assert Enum.count(s.async_actions[:demo].queue) == 1

    # Only the in-flight op has reported.
    assert_receive {:async_action_result, :demo, ^token1, :first}, @async_action_timeout
    refute_received {:async_action_result, :demo, _t, :second}
  end

  test "advance/2 starts the next queued op under a fresh token, FIFO order" do
    s =
      state()
      |> AsyncAction.run(:demo, fn -> :a end)

    ta = s.async_actions[:demo].running
    s = AsyncAction.run(s, :demo, fn -> :b end)
    s = AsyncAction.run(s, :demo, fn -> :c end)
    assert_receive {:async_action_result, :demo, ^ta, :a}, @async_action_timeout

    s = AsyncAction.advance(s, :demo)
    tb = s.async_actions[:demo].running
    refute tb == ta
    assert_receive {:async_action_result, :demo, ^tb, :b}, @async_action_timeout

    s = AsyncAction.advance(s, :demo)
    tc = s.async_actions[:demo].running
    assert_receive {:async_action_result, :demo, ^tc, :c}, @async_action_timeout

    # Draining the last op idles (removes) the lane.
    s = AsyncAction.advance(s, :demo)
    refute Map.has_key?(s.async_actions, :demo)
  end

  test "current? is true only for the in-flight token" do
    s = AsyncAction.run(state(), :demo, fn -> :x end)
    assert AsyncAction.current?(s, :demo, s.async_actions[:demo].running)
    refute AsyncAction.current?(s, :demo, make_ref())
    refute AsyncAction.current?(s, :other, make_ref())
  end

  test "lanes are independent" do
    s =
      state()
      |> AsyncAction.run(:git_worktree, fn -> :a end)
      |> AsyncAction.run(:file_tree, fn -> :b end)

    assert AsyncAction.current?(s, :git_worktree, s.async_actions[:git_worktree].running)
    assert AsyncAction.current?(s, :file_tree, s.async_actions[:file_tree].running)
  end

  test "a raising work function is captured as an error result, not a crash" do
    s = AsyncAction.run(state(), :demo, fn -> raise "boom" end)
    token = s.async_actions[:demo].running
    assert_receive {:async_action_result, :demo, ^token, {:error, "boom"}}, @async_action_timeout
  end

  test "a failing op still advances the lane so the queue does not wedge" do
    s = AsyncAction.run(state(), :demo, fn -> raise "boom" end)
    ta = s.async_actions[:demo].running
    s = AsyncAction.run(s, :demo, fn -> :next end)
    assert_receive {:async_action_result, :demo, ^ta, {:error, "boom"}}, @async_action_timeout

    s = AsyncAction.advance(s, :demo)
    tb = s.async_actions[:demo].running
    assert_receive {:async_action_result, :demo, ^tb, :next}, @async_action_timeout
  end
end
