defmodule MingaEditor.Extension.EventEffect.ResultTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Extension.EventDispatchResult
  alias MingaEditor.Extension.EventEffect.Result
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState

  test "every unchanged callback outcome refers to the request's snapshot" do
    base = %EditorState{workspace: %SessionState{}}
    failure = {:callback_failed, {:extension, :example}, __MODULE__, :callback, :error, :failed}

    results = [
      EventDispatchResult.handled(base),
      EventDispatchResult.not_matched(base),
      EventDispatchResult.callback_failed(base, [failure])
    ]

    for result <- results do
      compact = Result.from_dispatch(result, base)
      assert compact.state == :base
      resolved = Result.resolve(compact, base)
      assert resolved.state === base
      assert resolved.status == result.status
      assert resolved.failures == result.failures
    end
  end

  test "numerically equal extension values do not discard a changed candidate" do
    base = state_with_value(1)
    candidate = state_with_value(1.0)
    assert base == candidate
    refute base === candidate

    compact = Result.from_dispatch(EventDispatchResult.handled(candidate), base)
    resolved = Result.resolve(compact, base)
    assert resolved.state === candidate

    assert SessionState.get_feature_state(
             resolved.state.workspace,
             {:extension, :example},
             :value
           ) === 1.0
  end

  defp state_with_value(value) do
    workspace =
      SessionState.put_feature_state(%SessionState{}, {:extension, :example}, :value, value)

    %EditorState{workspace: workspace}
  end
end
