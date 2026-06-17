defmodule MingaEditor.AsyncActionTest do
  @moduledoc "Token-tagged offloading of slow editor work with stale-result protection."
  use ExUnit.Case, async: true

  alias MingaEditor.AsyncAction
  alias MingaEditor.State, as: EditorState

  defp state, do: %EditorState{port_manager: self(), workspace: nil}

  test "run/3 records a token and offloads the work, returning immediately" do
    s = AsyncAction.run(state(), :demo, fn -> send(self(), :work_ran) end)

    token = s.async_actions[:demo]
    assert is_reference(token)
    assert AsyncAction.current?(s, :demo, token)
    # The work runs in a Task and reports back asynchronously, not inline.
    assert_receive {:async_action_result, :demo, ^token, _result}
  end

  test "a newer run on the same lane supersedes the older token" do
    s1 = AsyncAction.run(state(), :demo, fn -> :a end)
    old = s1.async_actions[:demo]

    s2 = AsyncAction.run(s1, :demo, fn -> :b end)
    new = s2.async_actions[:demo]

    refute old == new
    # The out-of-order/stale result for `old` is no longer current and is dropped.
    refute AsyncAction.current?(s2, :demo, old)
    assert AsyncAction.current?(s2, :demo, new)
  end

  test "lanes are independent" do
    s =
      state()
      |> AsyncAction.run(:git_worktree, fn -> :a end)
      |> AsyncAction.run(:file_tree, fn -> :b end)

    assert AsyncAction.current?(s, :git_worktree, s.async_actions[:git_worktree])
    assert AsyncAction.current?(s, :file_tree, s.async_actions[:file_tree])
  end

  test "a raising work function is captured as an error result, not a crash" do
    AsyncAction.run(state(), :demo, fn -> raise "boom" end)
    assert_receive {:async_action_result, :demo, _token, {:error, "boom"}}
  end

  test "clear_async_token makes a later result non-current" do
    s = AsyncAction.run(state(), :demo, fn -> :x end)
    token = s.async_actions[:demo]

    cleared = EditorState.clear_async_token(s, :demo)
    refute AsyncAction.current?(cleared, :demo, token)
  end
end
