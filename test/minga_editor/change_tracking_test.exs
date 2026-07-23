defmodule MingaEditor.ChangeTrackingTest do
  use ExUnit.Case, async: true

  alias MingaEditor.ChangeRecorder
  alias MingaEditor.ChangeTracking
  alias MingaEditor.Editing
  alias MingaEditor.RenderPipeline.TestHelpers

  defp state_with_recorder(recorder) do
    TestHelpers.base_state(rendering: :disabled)
    |> Editing.set_change_recorder(recorder)
  end

  test "nested counted dot-repeat preserves outer replay and last change" do
    rec =
      ChangeRecorder.new()
      |> ChangeRecorder.start_recording()
      |> ChangeRecorder.record_key({?x, 0})
      |> ChangeRecorder.stop_recording()
      |> ChangeRecorder.start_replay()

    state = state_with_recorder(rec) |> ChangeTracking.replay_last_change(3)
    rec = Editing.change_recorder(state)

    assert rec.phase == {:replaying, 1, :idle}
    assert ChangeRecorder.replaying?(rec)
    assert ChangeRecorder.get_last_change(rec) == [{?x, 0}]

    rec = ChangeRecorder.stop_replay(rec)
    assert rec.phase == :idle
    assert ChangeRecorder.get_last_change(rec) == [{?x, 0}]
  end
end
