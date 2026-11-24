defmodule MingaEditor.Handlers.ProjectRebuildFailureTest do
  @moduledoc "Tests that a failed project rebuild leaves an open file picker's loading state."

  use ExUnit.Case, async: true

  alias Minga.Events.ProjectRebuildFailedEvent
  alias Minga.Events.ProjectRebuiltEvent
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Handlers.EventDispatcher
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.UI.Picker.FileSource

  test "a failed rebuild refetches a loading file picker so it can show the failure, and a later success refetches again" do
    {loading, loading_revision} = PickerUI.open_loading(state_with_scheduler(), FileSource)
    assert %{load_status: :loading} = picker_state(loading)

    failed = %ProjectRebuildFailedEvent{root: "/tmp/project", reason: "permission denied"}
    after_failure = dispatch(loading, :project_rebuild_failed, failed)

    failure_revision = picker_state(after_failure).fetch_revision
    assert is_reference(failure_revision)
    refute failure_revision == loading_revision

    recovered =
      dispatch(after_failure, :project_rebuilt, %ProjectRebuiltEvent{root: "/tmp/project"})

    refute picker_state(recovered).fetch_revision == failure_revision
  end

  test "a failed rebuild with no root leaves a closed picker untouched" do
    state = TestHelpers.base_state(rendering: :disabled)
    failed = %ProjectRebuildFailedEvent{root: nil, reason: "Project file cache rebuild timed out"}

    assert dispatch(state, :project_rebuild_failed, failed).shell_runtime ==
             state.shell_runtime
  end

  @spec dispatch(MingaEditor.State.t(), atom(), struct()) :: MingaEditor.State.t()
  defp dispatch(state, event, payload),
    do: EventDispatcher.dispatch(state, event, payload, {:minga_event, event, payload})

  @spec picker_state(MingaEditor.State.t()) :: MingaEditor.State.Picker.t()
  defp picker_state(state) do
    {:picker, payload} = state.shell_runtime.state.modal
    payload.picker_ui
  end

  @spec state_with_scheduler() :: MingaEditor.State.t()
  defp state_with_scheduler do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec({EffectScheduler, task_supervisor: task_supervisor}, id: make_ref())
      )

    :ok = EffectScheduler.attach(scheduler, self())
    %{TestHelpers.base_state(rendering: :disabled) | effect_scheduler: scheduler}
  end
end
