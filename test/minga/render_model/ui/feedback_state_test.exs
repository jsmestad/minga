defmodule Minga.RenderModel.UI.FeedbackStateTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.FeedbackState

  describe "new/0" do
    test "returns idle state" do
      fs = FeedbackState.new()
      assert fs.status == :idle
      assert fs.message == nil
      assert fs.queued == false
      assert fs.count == nil
    end
  end

  describe "start/2" do
    test "transitions to pending with message" do
      fs = FeedbackState.new() |> FeedbackState.start("Formatting…")
      assert fs.status == :pending
      assert fs.message == "Formatting…"
      assert fs.queued == false
    end

    test "transitions to pending without message" do
      fs = FeedbackState.new() |> FeedbackState.start()
      assert fs.status == :pending
      assert fs.message == nil
    end

    test "resets count from prior state" do
      fs =
        FeedbackState.new()
        |> FeedbackState.start("first")
        |> FeedbackState.update_count(3, 5)
        |> FeedbackState.start("second")

      assert fs.count == nil
    end
  end

  describe "mark_loading/1" do
    test "transitions pending to loading" do
      fs = FeedbackState.new() |> FeedbackState.start("Working…") |> FeedbackState.mark_loading()
      assert fs.status == :loading
      assert fs.message == "Working…"
    end

    test "no-ops on non-pending state" do
      fs = FeedbackState.new() |> FeedbackState.mark_loading()
      assert fs.status == :idle
    end
  end

  describe "succeed/2" do
    test "transitions to success with message" do
      fs = FeedbackState.new() |> FeedbackState.start("Working…") |> FeedbackState.succeed("Done")
      assert fs.status == :success
      assert fs.message == "Done"
    end

    test "preserves queued flag" do
      fs =
        FeedbackState.new()
        |> FeedbackState.start("Working…")
        |> FeedbackState.set_queued(true)
        |> FeedbackState.succeed("Done")

      assert fs.status == :success
      assert fs.queued == true
    end
  end

  describe "fail/2" do
    test "transitions to error with message" do
      fs = FeedbackState.new() |> FeedbackState.fail("Something went wrong")
      assert fs.status == :error
      assert fs.message == "Something went wrong"
    end
  end

  describe "mark_timeout/2" do
    test "transitions to timeout with message" do
      fs = FeedbackState.new() |> FeedbackState.mark_timeout("LSP timed out")
      assert fs.status == :timeout
      assert fs.message == "LSP timed out"
    end
  end

  describe "cancel/1" do
    test "transitions to canceled" do
      fs = FeedbackState.new() |> FeedbackState.start("Working…") |> FeedbackState.cancel()
      assert fs.status == :canceled
      assert fs.message == nil
    end
  end

  describe "clear/1" do
    test "resets to idle" do
      fs = FeedbackState.new() |> FeedbackState.succeed("Done") |> FeedbackState.clear()
      assert fs.status == :idle
      assert fs.message == nil
      assert fs.queued == false
      assert fs.count == nil
    end
  end

  describe "set_queued/2" do
    test "sets queued flag" do
      fs =
        FeedbackState.new() |> FeedbackState.start("Working…") |> FeedbackState.set_queued(true)

      assert fs.queued == true
    end

    test "clears queued flag" do
      fs =
        FeedbackState.new()
        |> FeedbackState.start("Working…")
        |> FeedbackState.set_queued(true)
        |> FeedbackState.set_queued(false)

      assert fs.queued == false
    end
  end

  describe "update_count/3" do
    test "sets count tuple" do
      fs =
        FeedbackState.new()
        |> FeedbackState.start("Renaming…")
        |> FeedbackState.update_count(3, 5)

      assert fs.count == {3, 5}
    end
  end

  describe "active?/1" do
    test "true for pending" do
      assert FeedbackState.active?(FeedbackState.start(FeedbackState.new(), "x"))
    end

    test "true for loading" do
      fs = FeedbackState.new() |> FeedbackState.start("x") |> FeedbackState.mark_loading()
      assert FeedbackState.active?(fs)
    end

    test "false for idle" do
      refute FeedbackState.active?(FeedbackState.new())
    end

    test "false for success" do
      refute FeedbackState.active?(FeedbackState.succeed(FeedbackState.new(), "Done"))
    end

    test "false for error" do
      refute FeedbackState.active?(FeedbackState.fail(FeedbackState.new(), "Failed"))
    end
  end

  describe "terminal?/1" do
    test "true for success" do
      assert FeedbackState.terminal?(FeedbackState.succeed(FeedbackState.new()))
    end

    test "true for error" do
      assert FeedbackState.terminal?(FeedbackState.fail(FeedbackState.new()))
    end

    test "true for timeout" do
      assert FeedbackState.terminal?(FeedbackState.mark_timeout(FeedbackState.new()))
    end

    test "true for canceled" do
      assert FeedbackState.terminal?(FeedbackState.cancel(FeedbackState.new()))
    end

    test "false for idle" do
      refute FeedbackState.terminal?(FeedbackState.new())
    end

    test "false for pending" do
      refute FeedbackState.terminal?(FeedbackState.start(FeedbackState.new()))
    end
  end

  describe "threshold constants" do
    test "spinner delay is 100ms" do
      assert FeedbackState.spinner_delay_ms() == 100
    end

    test "spinner hold is 500ms" do
      assert FeedbackState.spinner_hold_ms() == 500
    end

    test "success dwell is 1500ms" do
      assert FeedbackState.success_dwell_ms() == 1_500
    end
  end
end
