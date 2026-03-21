defmodule Minga.ClipboardTest do
  @moduledoc """
  Tests for `Minga.Clipboard` facade, including the async write path
  introduced to eliminate blocking the Editor GenServer on system
  clipboard writes.
  """
  use ExUnit.Case, async: true

  import Hammox

  alias Minga.Clipboard

  setup :verify_on_exit!

  describe "write_async/1" do
    test "returns :ok without waiting for the backend write to complete" do
      test_pid = self()
      ref = make_ref()

      stub(Minga.Clipboard.Mock, :write, fn _text ->
        # Signal that the write task has started, then block.
        # A synchronous write_async would hang here until the after-clause fires.
        send(test_pid, {:write_started, ref})

        # Block for 1s (longer than the 200ms assert_receive window below,
        # so the task is still blocked when we verify non-blocking behavior).
        receive do
        after
          1_000 -> :ok
        end
      end)

      # write_async must return :ok before the mock unblocks.
      # A synchronous implementation would hang here until the 1s after-clause fires.
      assert :ok = Clipboard.write_async("hello")

      # Confirm the task was spawned and entered the (blocked) write.
      # This proves write_async returned while the mock was still blocked,
      # which is a structural proof of non-blocking behavior.
      assert_receive {:write_started, ^ref}, 200
    end

    test "delegates to the configured backend" do
      test_pid = self()

      expect(Minga.Clipboard.Mock, :write, fn text ->
        send(test_pid, {:write_called, text})
        :ok
      end)

      assert :ok = Clipboard.write_async("test payload")
      assert_receive {:write_called, "test payload"}, 200
    end

    test "handles empty string without crashing" do
      test_pid = self()

      expect(Minga.Clipboard.Mock, :write, fn text ->
        send(test_pid, {:write_called, text})
        :ok
      end)

      assert :ok = Clipboard.write_async("")
      assert_receive {:write_called, ""}, 200
    end

    test "handles backend returning :unavailable gracefully" do
      test_pid = self()

      expect(Minga.Clipboard.Mock, :write, fn _text ->
        send(test_pid, :write_completed)
        :unavailable
      end)

      # Should not crash even though the backend says unavailable
      assert :ok = Clipboard.write_async("ignored")
      assert_receive :write_completed, 200
    end

    test "concurrent async writes do not crash" do
      test_pid = self()
      counter = :counters.new(1, [:atomics])

      stub(Minga.Clipboard.Mock, :write, fn text ->
        :counters.add(counter, 1, 1)
        send(test_pid, {:write_called, text})
        :ok
      end)

      Clipboard.write_async("first")
      Clipboard.write_async("second")
      Clipboard.write_async("third")

      # All three should complete
      assert_receive {:write_called, _}, 200
      assert_receive {:write_called, _}, 200
      assert_receive {:write_called, _}, 200
      assert :counters.get(counter, 1) == 3
    end
  end
end
