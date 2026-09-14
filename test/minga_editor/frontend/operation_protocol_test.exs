defmodule MingaEditor.Frontend.OperationProtocolTest do
  use ExUnit.Case, async: true

  alias Minga.Protocol.Opcodes
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.NativeIPC.OperationNativeResult
  alias MingaEditor.NativeIPC.OperationReceipt
  alias MingaEditor.NativeIPC.OperationReceipt.Evidence
  alias MingaEditor.NativeIPC.OperationReceipt.Target
  alias MingaEditor.PresentationTarget

  test "presentation target encodes exact target, pane, application revision, and focus postcondition" do
    target = %PresentationTarget{token: 0x0102_0304_0506_0708, window_id: 9, focus_required: true}

    assert <<opcode, 0x0102_0304_0506_0708::unsigned-64, 9::16, 42::32, 1>> =
             Protocol.encode_presentation_target(target, 42)

    assert opcode == Opcodes.presentation_target()
  end

  test "presentation operation encodes scoped operation and the applied target revision" do
    target = %Target{token: 18, path: "/tmp/protocol.txt", window_id: 3}

    receipt = %OperationReceipt{
      app_instance_id: "app",
      core_instance_id: "core",
      operation_id: 17,
      kind: :open,
      target: target,
      postcondition: :editor_visible_focused,
      phase: :applied,
      application_revision: 44,
      admitted_at_ms: 1,
      applied_at_ms: 2
    }

    assert <<opcode, 17::unsigned-64, 18::unsigned-64, 3::16, 44::32, 1>> =
             Protocol.encode_presentation_operation(receipt)

    assert opcode == Opcodes.presentation_operation()
  end

  test "native result decodes attempted and last-visible target evidence" do
    opcode = Opcodes.operation_native_result()

    payload =
      <<opcode, 71::unsigned-64, 72::unsigned-64, 3::32, 10::32, 4::16, 0, 1, 1, 44::32,
        61::unsigned-64, 2::32, 9::32, 1::16, 1, 43::32>>

    assert {:ok, {:operation_native_result, %OperationNativeResult{} = result}} =
             Protocol.decode_event(payload)

    assert result.operation_id == 71
    assert result.target_token == 72
    assert result.outcome == :ready

    assert result.evidence == %Evidence{
             target_token: 72,
             application_revision: 44,
             boundary: :metal_drawable_completed,
             generation: 3,
             frame_seq: 10,
             window_id: 4,
             focus_ready: true
           }

    assert result.last_visible == %Evidence{
             target_token: 61,
             application_revision: 43,
             boundary: :metal_drawable_completed,
             generation: 2,
             frame_seq: 9,
             window_id: 1,
             focus_ready: true
           }
  end

  test "native result rejects malformed outcomes, boundaries, booleans, and lengths" do
    opcode = Opcodes.operation_native_result()

    valid =
      <<opcode, 1::unsigned-64, 2::unsigned-64, 3::32, 4::32, 5::16, 0, 1, 1, 6::32,
        0::unsigned-64, 0::32, 0::32, 0::16, 0, 0::32>>

    for {offset, invalid} <- [{27, 0xFF}, {28, 2}, {29, 0xFF}, {52, 2}] do
      assert {:error, :malformed} = Protocol.decode_event(put_byte(valid, offset, invalid))
    end

    assert {:error, :malformed} =
             Protocol.decode_event(binary_part(valid, 0, byte_size(valid) - 1))
  end

  defp put_byte(binary, offset, value) do
    <<head::binary-size(^offset), _old, tail::binary>> = binary
    <<head::binary, value, tail::binary>>
  end
end
