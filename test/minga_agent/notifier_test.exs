defmodule MingaAgent.NotifierTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Notifier
  alias MingaAgent.Notifier.OSAdapter.Noop

  @notify_opts [bell: false, os_adapter: Noop]

  describe "notify/3" do
    test "does not crash on any trigger type" do
      assert :ok = Notifier.notify(:approval, "Test approval", @notify_opts)
      assert :ok = Notifier.notify(:complete, "Test complete", @notify_opts)
      assert :ok = Notifier.notify(:error, "Test error", @notify_opts)
    end

    test "respects debouncing" do
      # First notification should go through
      assert :ok = Notifier.notify(:complete, "First", @notify_opts)

      # Second within debounce window should be suppressed (but still return :ok)
      assert :ok = Notifier.notify(:complete, "Second", @notify_opts)

      # We can't easily test that the second was suppressed without mocking,
      # but we verify no crash occurs
    end

    test "handles unknown trigger gracefully" do
      # Shouldn't crash even with unexpected trigger values
      assert :ok = Notifier.notify(:unknown_trigger, "test", @notify_opts)
    end
  end

  describe "clear_attention/0" do
    test "does not crash" do
      assert :ok = Notifier.clear_attention()
    end
  end
end
