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
    test "returns :ok immediately without blocking on the write" do
      test_pid = self()

      stub(Minga.Clipboard.Mock, :write, fn text ->
        # Simulate a slow clipboard tool
        Process.sleep(50)
        send(test_pid, {:write_done, text})
        :ok
      end)

      {time_μs, result} = :timer.tc(fn -> Clipboard.write_async("hello") end)

      assert result == :ok
      # write_async should return in well under 1ms (just spawns a Task)
      assert time_μs < 5_000, "write_async took #{time_μs}µs, expected < 5ms"

      # The actual write should happen eventually
      assert_receive {:write_done, "hello"}, 200
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
