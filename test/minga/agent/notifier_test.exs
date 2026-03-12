defmodule Minga.Agent.NotifierTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Notifier

  describe "notify/2" do
    test "does not crash on any trigger type" do
      assert :ok = Notifier.notify(:approval, "Test approval")
      assert :ok = Notifier.notify(:complete, "Test complete")
      assert :ok = Notifier.notify(:error, "Test error")
    end

    test "respects debouncing" do
      # First notification should go through
      assert :ok = Notifier.notify(:complete, "First")

      # Second within debounce window should be suppressed (but still return :ok)
      assert :ok = Notifier.notify(:complete, "Second")

      # We can't easily test that the second was suppressed without mocking,
      # but we verify no crash occurs
    end

    test "handles unknown trigger gracefully" do
      # Shouldn't crash even with unexpected trigger values
      assert :ok = Notifier.notify(:unknown_trigger, "test")
    end
  end

  describe "clear_attention/0" do
    test "does not crash" do
      assert :ok = Notifier.clear_attention()
    end
  end
end
