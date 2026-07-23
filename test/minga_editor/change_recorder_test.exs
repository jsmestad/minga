defmodule MingaEditor.ChangeRecorderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.ChangeRecorder

  describe "new/0" do
    test "returns a fresh recorder" do
      rec = ChangeRecorder.new()

      assert rec.phase == :idle
      assert rec.pending_keys == []
      assert ChangeRecorder.get_last_change(rec) == nil
      refute ChangeRecorder.recording?(rec)
      refute ChangeRecorder.replaying?(rec)
    end
  end

  describe "recording lifecycle" do
    test "start_recording promotes pending keys in original order" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.buffer_pending_key({?d, 0})
        |> ChangeRecorder.buffer_pending_key({?w, 0})
        |> ChangeRecorder.start_recording()

      assert rec.phase == {:recording, [{?d, 0}, {?w, 0}]}
      assert rec.pending_keys == []
      assert ChangeRecorder.recording?(rec)
    end

    test "record_key prepends keys while top-level recording" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?j, 0})
        |> ChangeRecorder.record_key({?k, 0})

      assert rec.phase == {:recording, [{?k, 0}, {?j, 0}]}
    end

    test "record_key is no-op when idle" do
      rec = ChangeRecorder.new() |> ChangeRecorder.record_key({?j, 0})
      assert rec.phase == :idle
    end

    test "record_key is no-op during top-level replay" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.start_replay()
        |> ChangeRecorder.record_key({?x, 0})

      assert rec.phase == {:replaying, 1, {:recording, [{?d, 0}]}}
    end

    test "stop_recording moves keys to last_change and returns idle" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.record_key({?w, 0})
        |> ChangeRecorder.stop_recording()

      assert rec.phase == :idle
      assert ChangeRecorder.get_last_change(rec) == [{?d, 0}, {?w, 0}]
    end

    test "stop_recording is no-op when not recording" do
      rec = ChangeRecorder.new() |> ChangeRecorder.stop_recording()

      assert rec.phase == :idle
      assert ChangeRecorder.get_last_change(rec) == nil
    end

    test "cancel_recording discards active and pending state without saving" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.buffer_pending_key({?2, 0})
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.cancel_recording()

      assert rec.phase == :idle
      assert rec.pending_keys == []
      assert ChangeRecorder.get_last_change(rec) == nil
    end

    test "cancel_recording preserves previous last_change" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?x, 0})
        |> ChangeRecorder.stop_recording()

      rec =
        rec
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.cancel_recording()

      assert ChangeRecorder.get_last_change(rec) == [{?x, 0}]
    end
  end

  describe "start_recording_if_not/1" do
    test "starts recording when not already recording" do
      rec = ChangeRecorder.new() |> ChangeRecorder.start_recording_if_not()
      assert rec.phase == {:recording, []}
    end

    test "preserves existing top-level recording" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.start_recording_if_not()

      assert rec.phase == {:recording, [{?d, 0}]}
    end

    test "preserves replay post recording" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_replay()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.start_recording_if_not()

      assert rec.phase == {:replaying, 1, {:recording, []}}
      assert ChangeRecorder.recording?(rec)
      assert ChangeRecorder.replaying?(rec)
    end
  end

  describe "replay phase" do
    test "start_replay wraps idle and stop_replay restores it" do
      rec = ChangeRecorder.new() |> ChangeRecorder.start_replay()
      assert rec.phase == {:replaying, 1, :idle}
      assert ChangeRecorder.replaying?(rec)

      rec = ChangeRecorder.stop_replay(rec)
      assert rec.phase == :idle
      refute ChangeRecorder.replaying?(rec)
    end

    test "start_replay wraps recording and restores after outer stop" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.start_replay()

      assert rec.phase == {:replaying, 1, {:recording, [{?d, 0}]}}
      assert ChangeRecorder.recording?(rec)
      assert ChangeRecorder.replaying?(rec)

      rec = ChangeRecorder.stop_replay(rec)
      assert rec.phase == {:recording, [{?d, 0}]}
    end

    test "nested replay decrements depth before restoring post phase" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.start_replay()
        |> ChangeRecorder.start_replay()

      assert rec.phase == {:replaying, 2, {:recording, []}}

      rec = ChangeRecorder.stop_replay(rec)
      assert rec.phase == {:replaying, 1, {:recording, []}}

      rec = ChangeRecorder.stop_replay(rec)
      assert rec.phase == {:recording, []}
    end

    test "stop_recording during replay stores post recording and preserves replay depth" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_replay()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.stop_recording()

      assert rec.phase == {:replaying, 1, :idle}
      assert ChangeRecorder.get_last_change(rec) == []
      assert ChangeRecorder.replaying?(rec)
      refute ChangeRecorder.recording?(rec)
    end
  end

  describe "replace_count/2" do
    test "returns keys unchanged when count is nil" do
      keys = [{?d, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, nil) == keys
    end

    test "strips leading count when count is 1" do
      keys = [{?3, 0}, {?d, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, 1) == [{?d, 0}, {?w, 0}]
    end

    test "prepends single-digit count" do
      keys = [{?d, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, 3) == [{?3, 0}, {?d, 0}, {?w, 0}]
    end

    test "prepends multi-digit count" do
      keys = [{?d, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, 12) == [{?1, 0}, {?2, 0}, {?d, 0}, {?w, 0}]
    end

    test "replaces existing leading digits" do
      keys = [{?3, 0}, {?d, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, 5) == [{?5, 0}, {?d, 0}, {?w, 0}]
    end

    test "strips multiple leading digits" do
      keys = [{?1, 0}, {?2, 0}, {?d, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, 4) == [{?4, 0}, {?d, 0}, {?w, 0}]
    end

    test "does not strip non-digit leading key" do
      keys = [{?d, 0}, {?3, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, 2) == [{?2, 0}, {?d, 0}, {?3, 0}, {?w, 0}]
    end
  end
end
