defmodule MingaEditor.Frontend.Manager.OutputPressureTest do
  use ExUnit.Case, async: true

  alias Minga.Protocol.Opcodes
  alias MingaEditor.Frontend.Manager.OutputPressure
  alias MingaEditor.Frontend.Manager.PendingFrame
  alias MingaEditor.Frontend.Protocol

  test "retains one current frame and coalesces one latest replacement" do
    first = frame(10, 9, 1)
    second = frame(11, 10, 1)
    latest = frame(12, 11, 1)

    assert {:attempt, pressure} = OutputPressure.enqueue(OutputPressure.new(), first)
    assert {:coalesced, pressure} = OutputPressure.enqueue(pressure, second)
    assert {:coalesced, pressure} = OutputPressure.enqueue(pressure, latest)

    stats = OutputPressure.stats(pressure)
    assert stats.current_frame_seq == 10
    assert stats.replacement_frame_seq == 12
    assert stats.current_bytes == PendingFrame.byte_size(first)
    assert stats.replacement_bytes == PendingFrame.byte_size(latest)
    assert stats.retained_bytes == stats.current_bytes + stats.replacement_bytes
  end

  test "admission promotes the coalesced replacement and preserves frame ordering metadata" do
    first = frame(10, 9, 1)
    replacement = frame(11, 10, 1)

    {:attempt, pressure} = OutputPressure.enqueue(OutputPressure.new(), first)
    {:coalesced, pressure} = OutputPressure.enqueue(pressure, replacement)
    assert {^first, pressure} = OutputPressure.admitted(pressure)
    assert pressure.current == replacement
    assert PendingFrame.follows?(replacement, first)
    refute PendingFrame.follows?(frame(12, 9, 1), first)
    assert PendingFrame.follows?(frame(12, 0, 2), first)
  end

  test "recovery raises the acknowledgement floor and only admitted frames can acknowledge" do
    failed = frame(11, 10, 3)
    {:attempt, pressure} = OutputPressure.enqueue(OutputPressure.new(), failed)
    pressure = OutputPressure.require_recovery(pressure, failed)

    assert OutputPressure.acknowledge(pressure, 3, 11) == :stale
    assert OutputPressure.acknowledge(pressure, 4, 12) == :stale

    recovery = frame(12, 0, 4)
    {:attempt, pressure} = OutputPressure.enqueue(pressure, recovery)
    assert {^recovery, pressure} = OutputPressure.admitted(pressure)
    assert {:accepted, pressure} = OutputPressure.acknowledge(pressure, 4, 12)
    assert OutputPressure.acknowledge(pressure, 4, 11) == :stale

    stats = OutputPressure.stats(pressure)
    assert stats.minimum_ack_generation == 4
    assert stats.last_admitted_generation == 4
    assert stats.last_admitted_frame_seq == 12
    assert stats.last_applied_generation == 4
    assert stats.last_applied_frame_seq == 12
    assert stats.retained_bytes == 0
  end

  test "frame admission bounds acknowledgements without future acknowledgements moving diagnostics" do
    first = frame(10, 9, 1)
    {:attempt, pressure} = OutputPressure.enqueue(OutputPressure.new(), first)
    assert {^first, pressure} = OutputPressure.admitted(pressure)
    assert {:accepted, pressure} = OutputPressure.acknowledge(pressure, 1, 10)

    assert OutputPressure.acknowledge(pressure, 1, 11) == :stale
    assert OutputPressure.acknowledge(pressure, 0xFFFFFFFF, 1) == :stale

    stats = OutputPressure.stats(pressure)
    assert stats.last_admitted_generation == 1
    assert stats.last_admitted_frame_seq == 10
    assert stats.last_applied_generation == 1
    assert stats.last_applied_frame_seq == 10
  end

  test "control batches coalesce by opcode" do
    first_font = Protocol.encode_set_font("First", 14, true, :regular)
    latest_font = Protocol.encode_set_font("Latest", 16, true, :regular)
    title = Protocol.encode_set_title("Minga")
    pressure = OutputPressure.new()
    pressure = OutputPressure.retain_control(pressure, Opcodes.set_font(), first_font)
    pressure = OutputPressure.retain_control(pressure, Opcodes.set_font(), latest_font)
    pressure = OutputPressure.retain_control(pressure, Opcodes.set_title(), title)

    stats = OutputPressure.stats(pressure)
    assert stats.control_batches == 2
    assert stats.control_bytes == byte_size(latest_font) + byte_size(title)
  end

  test "unwritable failure timing starts once and retry tokens are correlated" do
    pending = frame(7, 6, 1)
    {:attempt, pressure} = OutputPressure.enqueue(OutputPressure.new(), pending)
    first_token = make_ref()
    second_token = make_ref()
    pressure = OutputPressure.mark_unwritable(pressure, 100, first_token)
    pressure = OutputPressure.mark_unwritable(pressure, 120, second_token)

    refute OutputPressure.expired?(pressure, 149, 50)
    assert OutputPressure.expired?(pressure, 150, 50)
    assert OutputPressure.consume_retry(pressure, first_token) == :stale
    assert {:ok, pressure} = OutputPressure.consume_retry(pressure, second_token)
    assert pressure.retry_token == nil
  end

  test "revoking frames preserves controls and the shared unwritable interval" do
    first = frame(7, 6, 1)
    replacement = frame(8, 7, 1)
    control = Protocol.encode_set_title("Minga")
    token = make_ref()

    {:attempt, pressure} = OutputPressure.enqueue(OutputPressure.new(), first)
    {:coalesced, pressure} = OutputPressure.enqueue(pressure, replacement)

    pressure =
      pressure
      |> OutputPressure.retain_control(Opcodes.set_title(), control)
      |> OutputPressure.mark_unwritable(100, token)
      |> OutputPressure.revoke_frames()

    assert pressure.current == nil
    assert pressure.replacement == nil
    assert pressure.controls == %{Opcodes.set_title() => control}
    assert pressure.unwritable_since == 100
    assert pressure.retry_token == token
  end

  test "expired retained controls take terminal precedence over frame recovery" do
    frame = frame(7, 6, 1)
    control = Protocol.encode_set_title("Minga")
    token = make_ref()

    {:attempt, frame_only} = OutputPressure.enqueue(OutputPressure.new(), frame)
    frame_only = OutputPressure.mark_unwritable(frame_only, 100, token)
    assert OutputPressure.classify_timeout(frame_only, 150, 50) == {:recover_frame, frame}

    with_control =
      frame_only
      |> OutputPressure.retain_control(Opcodes.set_title(), control)

    assert OutputPressure.classify_timeout(with_control, 150, 50) == :transport_failure

    control_only =
      OutputPressure.new()
      |> OutputPressure.retain_control(Opcodes.set_title(), control)
      |> OutputPressure.mark_unwritable(100, token)

    assert OutputPressure.classify_timeout(control_only, 149, 50) == :continue
    assert OutputPressure.classify_timeout(control_only, 150, 50) == :transport_failure
  end

  test "terminal transport failure clears retained output and invalidates retry correlation" do
    frame = frame(7, 6, 1)
    control = Protocol.encode_set_title("Minga")
    token = make_ref()

    {:attempt, pressure} = OutputPressure.enqueue(OutputPressure.new(), frame)

    pressure =
      pressure
      |> OutputPressure.retain_control(Opcodes.set_title(), control)
      |> OutputPressure.mark_unwritable(100, token)
      |> OutputPressure.fail_transport()

    assert OutputPressure.consume_retry(pressure, token) == :stale
    assert OutputPressure.classify_timeout(pressure, 200, 50) == :continue
    assert OutputPressure.stats(pressure).total_retained_bytes == 0
  end

  defp frame(frame_seq, base_frame_seq, generation) do
    commands = [
      Protocol.encode_begin_frame(frame_seq, base_frame_seq, generation),
      Protocol.encode_commit_frame(frame_seq)
    ]

    assert {:ok, frame} = PendingFrame.from_commands(commands)
    frame
  end
end
