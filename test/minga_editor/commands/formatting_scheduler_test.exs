defmodule MingaEditor.Commands.FormattingSchedulerTest do
  @moduledoc "Integrated scheduler ownership regressions for external formatting."

  # External formatting launches a real shell process and this test sets global formatter options.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Config.Options
  alias MingaEditor.Commands.Formatting
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.ExternalFormat
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.OperationFeedback

  @effect_timeout 2_000

  test "origin creates feedback before scheduling and correlates the running lifecycle" do
    Options.set_for_filetype(:elixir, :formatter, "cat")

    on_exit(fn ->
      Options.reset()
      Options.set(:clipboard, :none)
    end)

    task_supervisor = start_supervised!({Task.Supervisor, []})

    scheduler =
      start_supervised!({EffectScheduler, task_supervisor: task_supervisor, observer: self()})

    :ok = EffectScheduler.attach(scheduler, self())

    state =
      TestHelpers.base_state(
        content: "defmodule Example, do: nil\n",
        effect_scheduler: scheduler,
        rendering: :disabled
      )

    state = Formatting.format_buffer(state)
    operation = OperationFeedback.selected(state.feedback.operation_feedback)

    assert operation.status == :pending
    assert is_integer(operation.id)

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{
                        operation_id: operation_id,
                        effect: %ExternalFormat{}
                      },
                      value: :running
                    } = lifecycle},
                   @effect_timeout

    assert operation_id == operation.id
    {:noreply, state} = MingaEditor.handle_info({:effect_lifecycle, lifecycle}, state)
    assert OperationFeedback.selected(state.feedback.operation_feedback).status == :running
  end

  test "superseded mailbox candidate cannot apply an old external format" do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    scheduler =
      start_supervised!(
        {EffectScheduler, task_supervisor: task_supervisor, observer: self(), max_admitted: 2}
      )

    :ok = EffectScheduler.attach(scheduler, self())
    state = TestHelpers.base_state(content: "old content\n", effect_scheduler: scheduler)
    buffer = state.workspace.buffers.active

    {old_feedback, old_operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :external_format,
        "buffer",
        "Formatting old"
      )

    state = %{state | feedback: Feedback.accept_operation_feedback(state.feedback, old_feedback)}

    old_request =
      ExternalFormat.request(buffer, "tr '[:lower:]' '[:upper:]'", old_operation.id)

    assert {:ok, old_id, :running} = EffectScheduler.schedule(scheduler, old_request)

    assert_receive {:effect_result, ^scheduler,
                    %Outcome{
                      request: %Request{id: ^old_id},
                      value: {:completed, _result}
                    } = old_candidate},
                   @effect_timeout

    {replacement_feedback, replacement_operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :external_format,
        "buffer",
        "Formatting replacement"
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, replacement_feedback)
    }

    replacement = ExternalFormat.request(buffer, "cat", replacement_operation.id)
    assert {:ok, _replacement_id, :running} = EffectScheduler.schedule(scheduler, replacement)

    assert_receive {:effect_terminal,
                    %Outcome{
                      request: %Request{id: ^old_id},
                      value: {:canceled, :superseded}
                    }},
                   @effect_timeout

    assert {:noreply, ^state} =
             MingaEditor.handle_info({:effect_result, scheduler, old_candidate}, state)

    assert Buffer.content(buffer) == "old content\n"
    _stats = EffectScheduler.stats(scheduler)
    refute_received {:effect_terminal, %Outcome{request: %Request{id: ^old_id}}}
  end
end
