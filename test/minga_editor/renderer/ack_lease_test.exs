defmodule MingaEditor.Renderer.AckLeaseTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.AckLease
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Renderer.FrameAttempt

  test "start stores attempt and output, derives generation, and schedules exact timeout" do
    attempt = FrameAttempt.new(intent(), 42, 100)
    output = input(7)

    lease = AckLease.start(attempt, output, 1)

    assert lease.attempt == attempt
    assert lease.output == output
    assert lease.generation == 7
    assert_receive {:frame_ack_timeout, 7, 42}
  end

  test "matches requires exact generation and sequence" do
    lease = AckLease.start(FrameAttempt.new(intent(), 42, 100), input(7), 1_000)
    on_exit(fn -> AckLease.cancel_timer(lease) end)

    assert AckLease.matches?(lease, 7, 42)
    refute AckLease.matches?(lease, 8, 42)
    refute AckLease.matches?(lease, 7, 43)
  end

  test "matches_base also requires the acknowledged base" do
    lease = AckLease.start(FrameAttempt.new(intent(), 42, 100), input(7), 1_000)
    on_exit(fn -> AckLease.cancel_timer(lease) end)

    assert AckLease.matches_base?(lease, 7, 42, 41, 41)
    refute AckLease.matches_base?(lease, 7, 42, 40, 41)
    refute AckLease.matches_base?(lease, 8, 42, 41, 41)
    refute AckLease.matches_base?(lease, 7, 43, 41, 41)
  end

  test "cancel_timer accepts nil and prevents a lease timeout" do
    lease = AckLease.start(FrameAttempt.new(intent(), 42, 100), input(7), 25)

    assert AckLease.cancel_timer(nil) == :ok
    assert AckLease.cancel_timer(lease) == :ok
    refute_receive {:frame_ack_timeout, 7, 42}, 100
  end

  defp intent, do: input(1).intent

  defp input(generation) do
    TestHelpers.base_state()
    |> Input.from_editor_state()
    |> Map.put(:caches, %Caches{recovery_generation: generation})
  end
end
