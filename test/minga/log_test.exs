defmodule Minga.LogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Config.Options

  setup do
    {:ok, opts} = Options.start_link(name: :"opts_#{System.unique_integer()}")

    # Store the server pid so Minga.Log can find it. We patch effective_level
    # instead since Minga.Log reads from the global Options agent.
    # For these tests we'll set levels on the global agent directly.
    on_exit(fn ->
      # Reset global options to defaults after each test,
      # preserving test-time overrides (e.g. clipboard: :none).
      Minga.Test.OptionsHelper.reset_for_test()
    end)

    %{opts: opts}
  end

  describe "effective_level/1" do
    test "falls back to global :log_level when subsystem is :default" do
      Options.set(:log_level, :warning)
      assert Minga.Log.effective_level(:render) == :warning
    end

    test "uses subsystem-specific level when set" do
      Options.set(:log_level, :info)
      Options.set(:log_level_render, :debug)
      assert Minga.Log.effective_level(:render) == :debug
    end

    test "each subsystem is independent" do
      Options.set(:log_level, :warning)
      Options.set(:log_level_render, :debug)
      Options.set(:log_level_lsp, :error)

      assert Minga.Log.effective_level(:render) == :debug
      assert Minga.Log.effective_level(:lsp) == :error
      assert Minga.Log.effective_level(:agent) == :warning
      assert Minga.Log.effective_level(:editor) == :warning
    end
  end

  describe "filtering" do
    test "debug message is suppressed when level is :info" do
      Options.set(:log_level, :info)
      Options.set(:log_level_render, :default)

      log =
        capture_log(fn ->
          Minga.Log.debug(:render, "should not appear")
        end)

      assert log == ""
    end

    test "debug message appears when subsystem level is :debug" do
      Options.set(:log_level, :info)
      Options.set(:log_level_render, :debug)

      # Need to temporarily allow debug at the Logger level too
      previous = Logger.level()
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          Minga.Log.debug(:render, "render timing")
        end)

      Logger.configure(level: previous)

      assert log =~ "render timing"
    end

    test "warning message passes through when level is :info" do
      Options.set(:log_level, :info)

      log =
        capture_log(fn ->
          Minga.Log.warning(:editor, "something happened")
        end)

      assert log =~ "something happened"
    end

    test ":none suppresses everything" do
      Options.set(:log_level_agent, :none)

      log =
        capture_log(fn ->
          Minga.Log.error(:agent, "critical failure")
        end)

      assert log == ""
    end

    test "accepts a zero-arity function for lazy evaluation" do
      Options.set(:log_level, :info)
      Options.set(:log_level_render, :default)

      # The function should never be called when suppressed
      Minga.Log.debug(:render, fn ->
        send(self(), :function_was_called)
        "expensive message"
      end)

      refute_received :function_was_called
    end
  end
end
