defmodule MingaEditor.MacroRecorderTest do
  @moduledoc """
  Unit tests for the MacroRecorder module.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.MacroRecorder

  describe "new/0" do
    test "returns a fresh recorder with no macros" do
      rec = MacroRecorder.new()
      assert rec.recording == nil
      assert rec.registers == %{}
      assert rec.replaying == false
      assert rec.last_register == nil
    end
  end

  describe "start_recording/2" do
    test "begins recording into the named register" do
      rec = MacroRecorder.new() |> MacroRecorder.start_recording("a")
      assert rec.recording == {"a", []}
    end
  end

  describe "record_key/2" do
    test "appends key to active recording" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.record_key({?j, 0})
        |> MacroRecorder.record_key({?k, 0})

      {_reg, keys} = rec.recording
      # Keys are stored in reverse (prepended)
      assert keys == [{?k, 0}, {?j, 0}]
    end

    test "no-op when not recording" do
      rec = MacroRecorder.new() |> MacroRecorder.record_key({?j, 0})
      assert rec.recording == nil
    end
  end

  describe "stop_recording/1" do
    test "stores the recorded keys in the register" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.record_key({?j, 0})
        |> MacroRecorder.record_key({?x, 0})
        |> MacroRecorder.stop_recording()

      assert rec.recording == nil
      assert MacroRecorder.get_macro(rec, "a") == [{?j, 0}, {?x, 0}]
    end

    test "no-op when not recording" do
      rec = MacroRecorder.new() |> MacroRecorder.stop_recording()
      assert rec.recording == nil
    end

    test "overwrites previous macro in same register" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.record_key({?j, 0})
        |> MacroRecorder.stop_recording()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.record_key({?k, 0})
        |> MacroRecorder.stop_recording()

      assert MacroRecorder.get_macro(rec, "a") == [{?k, 0}]
    end
  end

  describe "get_macro/2" do
    test "returns nil for unrecorded register" do
      rec = MacroRecorder.new()
      assert MacroRecorder.get_macro(rec, "z") == nil
    end

    test "returns stored key sequence" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_recording("b")
        |> MacroRecorder.record_key({?w, 0})
        |> MacroRecorder.stop_recording()

      assert MacroRecorder.get_macro(rec, "b") == [{?w, 0}]
    end
  end

  describe "recording?/1" do
    test "returns false when not recording" do
      assert MacroRecorder.recording?(MacroRecorder.new()) == false
    end

    test "returns {true, register} when recording" do
      rec = MacroRecorder.new() |> MacroRecorder.start_recording("c")
      assert MacroRecorder.recording?(rec) == {true, "c"}
    end
  end

  describe "multiple registers" do
    test "different registers store independent macros" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.record_key({?j, 0})
        |> MacroRecorder.stop_recording()
        |> MacroRecorder.start_recording("b")
        |> MacroRecorder.record_key({?k, 0})
        |> MacroRecorder.stop_recording()

      assert MacroRecorder.get_macro(rec, "a") == [{?j, 0}]
      assert MacroRecorder.get_macro(rec, "b") == [{?k, 0}]
    end
  end

  describe "replay flags" do
    test "start_replay/stop_replay toggle the flag" do
      rec = MacroRecorder.new()
      assert MacroRecorder.replaying?(rec) == false

      rec = MacroRecorder.start_replay(rec)
      assert MacroRecorder.replaying?(rec) == true

      rec = MacroRecorder.stop_replay(rec)
      assert MacroRecorder.replaying?(rec) == false
    end
  end
end
