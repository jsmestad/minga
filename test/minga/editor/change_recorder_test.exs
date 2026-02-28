defmodule Minga.Editor.ChangeRecorderTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.ChangeRecorder

  describe "new/0" do
    test "returns a fresh recorder" do
      rec = ChangeRecorder.new()
      refute ChangeRecorder.recording?(rec)
      refute ChangeRecorder.replaying?(rec)
      assert ChangeRecorder.get_last_change(rec) == nil
    end
  end

  describe "recording lifecycle" do
    test "start_recording enables recording and clears keys" do
      rec = ChangeRecorder.new()
      rec = ChangeRecorder.start_recording(rec)
      assert ChangeRecorder.recording?(rec)
      assert rec.keys == []
    end

    test "record_key appends keys while recording" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.record_key({?w, 0})

      # Keys are stored in reverse internally; stop_recording reverses them.
      assert Enum.reverse(rec.keys) == [{?d, 0}, {?w, 0}]
    end

    test "record_key is no-op when not recording" do
      rec = ChangeRecorder.new()
      rec = ChangeRecorder.record_key(rec, {?x, 0})
      assert rec.keys == []
    end

    test "stop_recording moves keys to last_change" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.record_key({?w, 0})
        |> ChangeRecorder.stop_recording()

      refute ChangeRecorder.recording?(rec)
      assert ChangeRecorder.get_last_change(rec) == [{?d, 0}, {?w, 0}]
      assert rec.keys == []
    end

    test "stop_recording is no-op when not recording" do
      rec = ChangeRecorder.new()
      rec = ChangeRecorder.stop_recording(rec)
      refute ChangeRecorder.recording?(rec)
      assert ChangeRecorder.get_last_change(rec) == nil
    end

    test "cancel_recording discards keys without saving" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.cancel_recording()

      refute ChangeRecorder.recording?(rec)
      assert ChangeRecorder.get_last_change(rec) == nil
      assert rec.keys == []
    end

    test "cancel_recording preserves previous last_change" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?x, 0})
        |> ChangeRecorder.stop_recording()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?y, 0})
        |> ChangeRecorder.cancel_recording()

      assert ChangeRecorder.get_last_change(rec) == [{?x, 0}]
    end

    test "successive recordings overwrite last_change" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?x, 0})
        |> ChangeRecorder.stop_recording()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.record_key({?w, 0})
        |> ChangeRecorder.stop_recording()

      assert ChangeRecorder.get_last_change(rec) == [{?d, 0}, {?w, 0}]
    end
  end

  describe "start_recording_if_not/1" do
    test "starts recording when not already recording" do
      rec = ChangeRecorder.new()
      rec = ChangeRecorder.start_recording_if_not(rec)
      assert ChangeRecorder.recording?(rec)
    end

    test "preserves existing keys when already recording" do
      rec =
        ChangeRecorder.new()
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key({?d, 0})
        |> ChangeRecorder.start_recording_if_not()

      assert ChangeRecorder.recording?(rec)
      assert rec.keys == [{?d, 0}]
    end
  end

  describe "replay flag" do
    test "start_replay / stop_replay toggle the flag" do
      rec = ChangeRecorder.new()
      refute ChangeRecorder.replaying?(rec)

      rec = ChangeRecorder.start_replay(rec)
      assert ChangeRecorder.replaying?(rec)

      rec = ChangeRecorder.stop_replay(rec)
      refute ChangeRecorder.replaying?(rec)
    end
  end

  describe "replace_count/2" do
    test "nil count returns keys unchanged" do
      keys = [{?d, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, nil) == keys
    end

    test "count of 1 strips leading digits" do
      keys = [{?3, 0}, {?d, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, 1) == [{?d, 0}, {?w, 0}]
    end

    test "new count replaces original count" do
      keys = [{?3, 0}, {?d, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, 5) == [{?5, 0}, {?d, 0}, {?w, 0}]
    end

    test "multi-digit count" do
      keys = [{?d, 0}, {?w, 0}]
      assert ChangeRecorder.replace_count(keys, 12) == [{?1, 0}, {?2, 0}, {?d, 0}, {?w, 0}]
    end

    test "strips multi-digit original count" do
      keys = [{?1, 0}, {?5, 0}, {?x, 0}]
      assert ChangeRecorder.replace_count(keys, 3) == [{?3, 0}, {?x, 0}]
    end

    test "no leading digits with new count prepends digits" do
      keys = [{?x, 0}]
      assert ChangeRecorder.replace_count(keys, 3) == [{?3, 0}, {?x, 0}]
    end
  end
end
