defmodule MingaEditor.Shell.Traditional.NoticeWorkflowTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.OperationFeedback

  import MingaEditor.RenderPipeline.TestHelpers

  test "public notice workflows reject legacy map-shaped editor state" do
    assert_raise FunctionClauseError, fn -> invoke(NoticeWorkflow, :publish, [%{}, "notice"]) end
    assert_raise FunctionClauseError, fn -> invoke(NoticeWorkflow, :acknowledge, [%{}]) end
    assert_raise FunctionClauseError, fn -> invoke(NoticeWorkflow, :dismiss, [%{}]) end
    assert_raise FunctionClauseError, fn -> invoke(NoticeWorkflow, :timeout, [%{}, 1]) end
    assert_raise FunctionClauseError, fn -> invoke(NoticeWorkflow, :message, [%{}]) end
  end

  test "publishes, replaces, acknowledges, and rejects stale timeout delivery" do
    state = base_state()
    first = NoticeWorkflow.publish(state, "first")
    first_id = first.shell_runtime.state.notice.id
    second = NoticeWorkflow.publish(first, "second")

    assert second.shell_runtime.state.notice.id == first_id + 1
    assert second.shell_runtime.state.notice.message == "second"
    assert NoticeWorkflow.timeout(second, first_id) == second
    assert NoticeWorkflow.acknowledge(second).shell_runtime.state.notice.message == nil
  end

  test "visible notices use the two-second policy and acknowledgement cancels the timer" do
    state = base_state(backend: :tui)
    published = NoticeWorkflow.publish(state, "timed notice")
    timer = published.shell_runtime.state.notice.timer

    remaining = Process.read_timer(timer)
    assert is_integer(remaining)
    assert remaining > 0 and remaining <= 2_000

    acknowledged = NoticeWorkflow.acknowledge(published)
    assert acknowledged.shell_runtime.state.notice.message == nil
    assert Process.read_timer(timer) == false
  end

  test "Editor timer messages expire only the matching notice identity" do
    first =
      [rendering: :disabled]
      |> base_state()
      |> NoticeWorkflow.publish("first")

    first_id = first.shell_runtime.state.notice.id
    replacement = NoticeWorkflow.publish(first, "replacement")
    replacement_id = replacement.shell_runtime.state.notice.id

    assert {:noreply, stale_delivery} =
             MingaEditor.handle_info({:notice_timeout, first_id}, replacement)

    assert stale_delivery.shell_runtime.state.notice.message == "replacement"

    assert {:noreply, expired} =
             MingaEditor.handle_info({:notice_timeout, replacement_id}, stale_delivery)

    assert expired.shell_runtime.state.notice.message == nil
  end

  test "terminal operation dwell does not suppress a newer notice" do
    state = base_state()

    {operation_feedback, operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :external_format,
        "buffer:terminal",
        "Formatting"
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    operation_feedback =
      OperationFeedback.finish(
        state.feedback.operation_feedback,
        operation.id,
        :success,
        "Formatted"
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    state = NoticeWorkflow.publish(state, "Saved")

    assert state.shell_runtime.state.notice.message == "Saved"
  end

  test "active operation feedback owns the lane and hidden notices are not retained" do
    state = base_state()
    assert :ok = Minga.Events.subscribe(:log_message, state.extension_surfaces.events_registry)
    state = NoticeWorkflow.publish(state, "old notice")

    {operation_feedback, operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :external_format,
        "buffer:notice-test",
        "Formatting",
        cancelable?: true
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    operation_feedback = state.feedback.operation_feedback
    state = NoticeWorkflow.publish(state, "hidden notice")

    assert state.shell_runtime.state.notice.message == nil
    assert state.feedback.operation_feedback == operation_feedback

    assert_receive {:minga_event, :log_message,
                    %Minga.Events.LogMessageEvent{text: "hidden notice", level: :info}}

    assert {:ok, retained_operation} =
             OperationFeedback.fetch(state.feedback.operation_feedback, operation.id)

    assert retained_operation.message == "Formatting"
  end

  # The indirection lets runtime boundary tests pass intentionally invalid typed values.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp invoke(module, function, arguments), do: apply(module, function, arguments)
end
