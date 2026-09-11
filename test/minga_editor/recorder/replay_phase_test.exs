defmodule MingaEditor.Recorder.ReplayPhaseTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Recorder.ReplayPhase

  test "starts, nests, and restores a replay phase" do
    assert ReplayPhase.start(:idle) == {:replaying, 1, :idle}
    assert ReplayPhase.start({:replaying, 1, :idle}) == {:replaying, 2, :idle}
    assert ReplayPhase.stop({:replaying, 2, :idle}) == {:replaying, 1, :idle}
    assert ReplayPhase.stop({:replaying, 1, :idle}) == :idle
  end

  test "leaves non-replay phases unchanged when stopped" do
    phase = {:recording, [{?x, 0}]}

    assert ReplayPhase.stop(phase) == phase
    refute ReplayPhase.active?(phase)
    assert ReplayPhase.active?({:replaying, 1, phase})
  end
end
