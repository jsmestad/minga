defmodule MingaEditor.Commands.FormattingSchedulerTest do
  @moduledoc "Integrated scheduler ownership regressions for external formatting."

  # External formatting launches a real shell process, which must not run concurrently in ExUnit.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.ExternalFormat
  alias MingaEditor.RenderPipeline.TestHelpers

  @effect_timeout 2_000

  test "superseded mailbox candidate cannot apply an old external format" do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    scheduler =
      start_supervised!(
        {EffectScheduler, task_supervisor: task_supervisor, observer: self(), max_admitted: 2}
      )

    :ok = EffectScheduler.attach(scheduler, self())
    state = TestHelpers.base_state(content: "old content\n", effect_scheduler: scheduler)
    buffer = state.workspace.buffers.active

    old_request = ExternalFormat.request(buffer, "tr '[:lower:]' '[:upper:]'")
    assert {:ok, old_id, :running} = EffectScheduler.schedule(scheduler, old_request)

    assert_receive {:effect_result, ^scheduler,
                    %Outcome{
                      request: %Request{id: ^old_id},
                      status: :completed
                    } = old_candidate},
                   @effect_timeout

    replacement = ExternalFormat.request(buffer, "cat")
    assert {:ok, _replacement_id, :running} = EffectScheduler.schedule(scheduler, replacement)

    assert_receive {:effect_terminal,
                    %Outcome{
                      request: %Request{id: ^old_id},
                      status: :canceled,
                      reason: :superseded
                    }},
                   @effect_timeout

    assert {:noreply, ^state} =
             MingaEditor.handle_info({:effect_result, scheduler, old_candidate}, state)

    assert Buffer.content(buffer) == "old content\n"
    _stats = EffectScheduler.stats(scheduler)
    refute_received {:effect_terminal, %Outcome{request: %Request{id: ^old_id}}}
  end
end
