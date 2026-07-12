defmodule Minga.Parser.ParseSchedulerTest do
  use ExUnit.Case, async: true

  alias Minga.Parser.ParseScheduler

  test "admits one active buffer and coalesces duplicate readiness" do
    first = self()
    second = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(second), do: send(second, :stop) end)

    scheduler =
      ParseScheduler.new()
      |> ParseScheduler.enqueue(first)
      |> ParseScheduler.enqueue(first)
      |> ParseScheduler.enqueue(second)

    assert {:ok, ^first, active} = ParseScheduler.activate_next(scheduler)
    assert ParseScheduler.activate_next(active) == :busy
    assert ParseScheduler.active?(active, first)
    refute ParseScheduler.active?(active, second)

    timer_ref = Process.send_after(self(), :scheduler_timeout_test, 60_000)
    active = ParseScheduler.arm_timeout(active, {:parse, 1}, timer_ref)
    assert ParseScheduler.timeout?(active, first, {:parse, 1})
    refute ParseScheduler.timeout?(active, first, {:parse, 2})
    assert ParseScheduler.timeout_ref(active) == timer_ref
    Process.cancel_timer(timer_ref)

    active = ParseScheduler.enqueue(active, first)

    released = ParseScheduler.release(active, first)
    assert ParseScheduler.timeout_ref(released) == nil
    assert {:ok, ^second, second_active} = ParseScheduler.activate_next(released)

    assert second_active |> ParseScheduler.release(second) |> ParseScheduler.activate_next() ==
             :empty
  end

  test "reset discards active and queued work" do
    scheduler =
      ParseScheduler.new()
      |> ParseScheduler.enqueue(self())

    assert {:ok, _buffer, active} = ParseScheduler.activate_next(scheduler)
    assert active |> ParseScheduler.reset() |> ParseScheduler.activate_next() == :empty
  end
end
