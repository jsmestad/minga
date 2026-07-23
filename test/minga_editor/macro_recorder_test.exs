defmodule MingaEditor.MacroRecorderTest do
  @moduledoc """
  Unit tests for the MacroRecorder module.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.MacroRecorder

  describe "new/0" do
    test "returns a fresh recorder with no macros" do
      rec = MacroRecorder.new()

      assert rec.phase == :idle
      assert rec.registers == %{}
      assert MacroRecorder.last_register(rec) == nil
      assert MacroRecorder.recording?(rec) == false
      assert MacroRecorder.replaying?(rec) == false
    end
  end

  describe "start_recording/2" do
    test "begins recording into the named register" do
      rec = MacroRecorder.new() |> MacroRecorder.start_recording("a")

      assert rec.phase == {:recording, "a", []}
      assert MacroRecorder.last_register(rec) == "a"
    end
  end

  describe "record_key/2" do
    test "appends key to active top-level recording" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.record_key({?j, 0})
        |> MacroRecorder.record_key({?k, 0})

      assert rec.phase == {:recording, "a", [{?k, 0}, {?j, 0}]}
    end

    test "no-op when not recording" do
      rec = MacroRecorder.new() |> MacroRecorder.record_key({?j, 0})
      assert rec.phase == :idle
    end

    test "no-op during top-level replay" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.record_key({?j, 0})
        |> MacroRecorder.start_replay()
        |> MacroRecorder.record_key({?x, 0})

      assert rec.phase == {:replaying, 1, {:recording, "a", [{?j, 0}]}}
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

      assert rec.phase == :idle
      assert MacroRecorder.get_macro(rec, "a") == [{?j, 0}, {?x, 0}]
      assert MacroRecorder.last_register(rec) == "a"
    end

    test "no-op when not recording" do
      rec = MacroRecorder.new() |> MacroRecorder.stop_recording()
      assert rec.phase == :idle
    end

    test "overwrites previous macro in same register" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.put_macro("a", [{?o, 0}])
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.record_key({?n, 0})
        |> MacroRecorder.stop_recording()

      assert MacroRecorder.get_macro(rec, "a") == [{?n, 0}]
    end

    test "q a q stores post recording and preserves replay depth" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_replay()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.stop_recording()

      assert rec.phase == {:replaying, 1, :idle}
      assert MacroRecorder.get_macro(rec, "a") == []
      assert MacroRecorder.last_register(rec) == "a"
      assert MacroRecorder.replaying?(rec)
      assert MacroRecorder.recording?(rec) == false
    end
  end

  describe "get_macro/2 and put_macro/3" do
    test "returns nil for missing register" do
      assert MacroRecorder.get_macro(MacroRecorder.new(), "z") == nil
    end

    test "stores and retrieves pre-built macros without phase or last-register changes" do
      rec = MacroRecorder.new() |> MacroRecorder.put_macro("a", [{?x, 0}])

      assert MacroRecorder.get_macro(rec, "a") == [{?x, 0}]
      assert rec.phase == :idle
      assert MacroRecorder.last_register(rec) == nil
    end

    test "keeps multiple registers separate" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.put_macro("a", [{?a, 0}])
        |> MacroRecorder.put_macro("b", [{?b, 0}])

      assert MacroRecorder.get_macro(rec, "a") == [{?a, 0}]
      assert MacroRecorder.get_macro(rec, "b") == [{?b, 0}]
    end
  end

  describe "recording?/1" do
    test "returns false when not recording" do
      assert MacroRecorder.recording?(MacroRecorder.new()) == false
    end

    test "returns {true, register} when top-level recording" do
      rec = MacroRecorder.new() |> MacroRecorder.start_recording("c")
      assert MacroRecorder.recording?(rec) == {true, "c"}
    end

    test "exposes post recording while replaying" do
      rec =
        MacroRecorder.new() |> MacroRecorder.start_replay() |> MacroRecorder.start_recording("c")

      assert MacroRecorder.recording?(rec) == {true, "c"}
      assert MacroRecorder.replaying?(rec) == true
    end
  end

  describe "replay phase" do
    test "start_replay wraps idle and stop_replay restores it" do
      rec = MacroRecorder.new() |> MacroRecorder.start_replay()
      assert rec.phase == {:replaying, 1, :idle}
      assert MacroRecorder.replaying?(rec) == true

      rec = MacroRecorder.stop_replay(rec)
      assert rec.phase == :idle
      assert MacroRecorder.replaying?(rec) == false
    end

    test "start_replay wraps recording and restores after outer stop" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.record_key({?x, 0})
        |> MacroRecorder.start_replay()

      assert rec.phase == {:replaying, 1, {:recording, "a", [{?x, 0}]}}

      rec = MacroRecorder.stop_replay(rec)
      assert rec.phase == {:recording, "a", [{?x, 0}]}
    end

    test "nested replay decrements depth before restoring post phase" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.start_replay()
        |> MacroRecorder.start_replay()

      assert rec.phase == {:replaying, 2, {:recording, "a", []}}

      rec = MacroRecorder.stop_replay(rec)
      assert rec.phase == {:replaying, 1, {:recording, "a", []}}

      rec = MacroRecorder.stop_replay(rec)
      assert rec.phase == {:recording, "a", []}
    end
  end

  describe "replay-time owner transitions" do
    test "q a x leaves active recording without recording replayed x" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.start_replay()
        |> MacroRecorder.start_recording("a")
        |> MacroRecorder.record_key({?x, 0})
        |> MacroRecorder.stop_replay()

      assert rec.phase == {:recording, "a", []}
      assert MacroRecorder.last_register(rec) == "a"
    end

    test "select_replay_register changes only last register" do
      rec = MacroRecorder.new() |> MacroRecorder.put_macro("a", [{?x, 0}])
      updated = MacroRecorder.select_replay_register(rec, "a")

      assert MacroRecorder.last_register(updated) == "a"
      assert updated.phase == rec.phase
      assert updated.registers == rec.registers
    end
  end
end
