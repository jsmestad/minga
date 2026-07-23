defmodule MingaEditor.Commands.MacroCommandsTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Commands
  alias MingaEditor.Commands.Macros
  alias MingaEditor.Editing
  alias MingaEditor.MacroRecorder
  alias MingaEditor.MacroReplay
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  defp state_with_recorder(recorder) do
    TestHelpers.base_state(rendering: :disabled)
    |> Editing.set_macro_recorder(recorder)
  end

  defp recorder(state), do: Editing.macro_recorder(state)

  describe "command selection" do
    test "successful replay selection updates last register and returns replay action" do
      state = state_with_recorder(MacroRecorder.put_macro(MacroRecorder.new(), "a", [{?x, 0}]))

      {updated, {:replay_macro, "a"}} = Commands.execute(state, {:replay_macro, "a"})

      assert MacroRecorder.last_register(recorder(updated)) == "a"
      refute MacroRecorder.replaying?(recorder(updated))
    end

    test "missing register leaves previous last register unchanged" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.select_replay_register("a")

      updated = state_with_recorder(rec) |> Commands.execute({:replay_macro, "z"})

      assert NoticeWorkflow.message(updated) == "No macro in register @z"
      assert MacroRecorder.last_register(recorder(updated)) == "a"
    end

    test "replay_last reports nil last register and replays non-nil last register" do
      state = state_with_recorder(MacroRecorder.new())
      assert NoticeWorkflow.message(Macros.replay_last(state)) == "No previous macro"

      rec = MacroRecorder.new() |> MacroRecorder.select_replay_register("b")
      state = state_with_recorder(rec)
      assert Macros.replay_last(state) == {state, {:replay_macro, "b"}}
    end
  end

  describe "workflow replay transition equivalence" do
    test "q a x restores active recording without recording replayed x" do
      rec = MacroRecorder.new() |> MacroRecorder.put_macro("a", [{?q, 0}, {?a, 0}, {?x, 0}])
      state = state_with_recorder(rec) |> MacroReplay.replay("a")
      rec = recorder(state)

      refute MacroRecorder.replaying?(rec)
      assert MacroRecorder.recording?(rec) == {true, "a"}
      assert rec.phase == {:recording, "a", []}
      assert MacroRecorder.last_register(rec) == "a"
    end

    test "q a q stores an empty macro and clears post recording" do
      rec = MacroRecorder.new() |> MacroRecorder.put_macro("a", [{?q, 0}, {?a, 0}, {?q, 0}])
      state = state_with_recorder(rec) |> MacroReplay.replay("a")
      rec = recorder(state)

      refute MacroRecorder.replaying?(rec)
      assert MacroRecorder.recording?(rec) == false
      assert MacroRecorder.get_macro(rec, "a") == []
      assert MacroRecorder.last_register(rec) == "a"
      assert Editing.mode_state(state).pending == nil
    end

    test "q a q b does not treat trailing b as a register selection" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.put_macro("a", [{?q, 0}, {?a, 0}, {?q, 0}, {?b, 0}])

      state = state_with_recorder(rec) |> MacroReplay.replay("a")
      rec = recorder(state)

      refute MacroRecorder.replaying?(rec)
      assert MacroRecorder.recording?(rec) == false
      assert MacroRecorder.get_macro(rec, "a") == []
      assert MacroRecorder.last_register(rec) == "a"
      assert Editing.mode_state(state).pending == nil
    end

    test "nested successful macro replay remains suppressed through outer trailing keys" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.put_macro("b", [{?h, 0}])
        |> MacroRecorder.put_macro("a", [{?q, 0}, {?c, 0}, {?@, 0}, {?b, 0}, {?x, 0}])

      state = state_with_recorder(rec) |> MacroReplay.replay("a")
      rec = recorder(state)

      refute MacroRecorder.replaying?(rec)
      assert MacroRecorder.recording?(rec) == {true, "c"}
      assert MacroRecorder.last_register(rec) == "b"

      stopped = MacroRecorder.stop_recording(rec)
      assert MacroRecorder.get_macro(stopped, "c") == []
    end

    test "nested missing macro preserves post-recording register and reports notice" do
      rec =
        MacroRecorder.new()
        |> MacroRecorder.put_macro("a", [{?q, 0}, {?c, 0}, {?@, 0}, {?z, 0}, {?x, 0}])

      state = state_with_recorder(rec) |> MacroReplay.replay("a")
      rec = recorder(state)

      assert NoticeWorkflow.message(state) == "No macro in register @z"
      refute MacroRecorder.replaying?(rec)
      assert MacroRecorder.recording?(rec) == {true, "c"}
      assert MacroRecorder.last_register(rec) == "c"

      stopped = MacroRecorder.stop_recording(rec)
      assert MacroRecorder.get_macro(stopped, "c") == []
    end
  end
end
