defmodule MingaEditor.Shell.Traditional.NoticeWorkflowTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State.OperationFeedback

  import MingaEditor.RenderPipeline.TestHelpers

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
    state = %{base_state() | backend: :port}
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
    first = NoticeWorkflow.publish(base_state(), "first")
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
    {state, operation} =
      OperationFeedback.start_in(base_state(), :external_format, "buffer:terminal", "Formatting")

    state = OperationFeedback.finish_in(state, operation.id, :success, "Formatted")
    state = NoticeWorkflow.publish(state, "Saved")

    assert state.shell_runtime.state.notice.message == "Saved"
  end

  test "active operation feedback owns the lane and hidden notices are not retained" do
    state = base_state()
    assert :ok = Minga.Events.subscribe(:log_message, state.events_registry)
    state = NoticeWorkflow.publish(state, "old notice")

    {state, operation} =
      OperationFeedback.start_in(state, :external_format, "buffer:notice-test", "Formatting",
        cancelable?: true
      )

    operation_feedback = state.operation_feedback
    state = NoticeWorkflow.publish(state, "hidden notice")

    assert state.shell_runtime.state.notice.message == nil
    assert state.operation_feedback == operation_feedback

    assert_receive {:minga_event, :log_message,
                    %Minga.Events.LogMessageEvent{text: "hidden notice", level: :info}}

    assert {:ok, retained_operation} =
             OperationFeedback.fetch(state.operation_feedback, operation.id)

    assert retained_operation.message == "Formatting"
  end
end
