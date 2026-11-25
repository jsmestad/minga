defmodule MingaEditor.State.BufferLifecycleCrashTest do
  @moduledoc "The crash a monitored buffer announces is held until the buffer is retired, and used once."

  use ExUnit.Case, async: true

  alias Minga.Events.BufferCrashedEvent
  alias MingaEditor.State.BufferLifecycle

  defp crash(pid),
    do: %BufferCrashedEvent{
      buffer: pid,
      path: "/project/notes.txt",
      swap_path: "/swap/notes.swap"
    }

  defp monitored(pid), do: BufferLifecycle.record_monitor(%BufferLifecycle{}, pid, make_ref())

  test "a monitored buffer's crash is taken once" do
    pid = self()
    lifecycle = pid |> monitored() |> BufferLifecycle.record_crash(crash(pid))

    assert {%BufferCrashedEvent{swap_path: "/swap/notes.swap"}, lifecycle} =
             BufferLifecycle.take_crash(lifecycle, pid)

    assert {nil, ^lifecycle} = BufferLifecycle.take_crash(lifecycle, pid)
  end

  test "a crash from a buffer this editor does not monitor is ignored" do
    lifecycle = BufferLifecycle.record_crash(%BufferLifecycle{}, crash(self()))

    assert lifecycle == %BufferLifecycle{}
    assert {nil, _lifecycle} = BufferLifecycle.take_crash(lifecycle, self())
  end

  test "a buffer that stops without announcing a crash has none" do
    assert {nil, _lifecycle} = BufferLifecycle.take_crash(monitored(self()), self())
  end

  test "retiring the monitor forgets an untaken crash" do
    pid = self()

    lifecycle =
      pid
      |> monitored()
      |> BufferLifecycle.record_crash(crash(pid))
      |> BufferLifecycle.retire_monitor(pid)

    assert lifecycle == %BufferLifecycle{}
  end
end
