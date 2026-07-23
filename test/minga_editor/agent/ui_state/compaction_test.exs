defmodule MingaEditor.Agent.UIState.CompactionTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState.Compaction

  test "new state starts fresh and idle" do
    assert Compaction.new() == %Compaction{threshold: :fresh, execution: :idle}
  end

  test "context usage below thresholds leaves state unchanged" do
    compaction = Compaction.new()

    assert Compaction.record_context_usage(compaction, 79, :idle, 80, 90, true) ==
             {compaction, :none}
  end

  test "warning threshold warns once" do
    compaction = Compaction.new()

    assert {%Compaction{threshold: :warned, execution: :idle} = warned, {:warn, 80}} =
             Compaction.record_context_usage(compaction, 80, :idle, 80, 90, true)

    assert Compaction.record_context_usage(warned, 85, :idle, 80, 90, true) == {warned, :none}
  end

  test "busy statuses defer the latest fill percentage" do
    assert {%Compaction{threshold: :fresh, execution: {:deferred, 95}} = deferred, :none} =
             Compaction.record_context_usage(Compaction.new(), 95, :thinking, 80, 90, true)

    assert {%Compaction{threshold: :fresh, execution: {:deferred, 96}}, :none} =
             Compaction.record_context_usage(deferred, 96, :tool_executing, 80, 90, true)
  end

  test "idle consumes deferred fill after resetting threshold gates" do
    compaction = %Compaction{threshold: :warned, execution: {:deferred, 95}}

    assert {%Compaction{threshold: :triggered, execution: :requested}, :schedule} =
             Compaction.status_changed(compaction, :idle, 80, 90, true)
  end

  test "auto threshold requires an active schedulable session" do
    compaction = Compaction.new()

    assert Compaction.record_context_usage(compaction, 95, :idle, 80, 90, false) ==
             {compaction, :none}
  end

  test "requested execution admits only one request at a time" do
    compaction = %Compaction{threshold: :triggered, execution: :requested}

    assert Compaction.record_context_usage(compaction, 95, :idle, 80, 90, true) ==
             {compaction, :none}
  end

  test "finish clears execution and preserves threshold" do
    assert Compaction.finish(%Compaction{threshold: :triggered, execution: :requested}) ==
             %Compaction{threshold: :triggered, execution: :idle}
  end
end
