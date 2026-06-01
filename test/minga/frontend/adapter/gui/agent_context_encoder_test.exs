defmodule Minga.Frontend.Adapter.GUI.AgentContextEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.AgentContextEncoder
  alias Minga.RenderModel.UI.AgentContext

  @op_gui_agent_context Minga.Protocol.Opcodes.gui_agent_context()

  describe "encode/2" do
    test "encodes hidden agent context" do
      model = %AgentContext{visible: false}
      caches = Caches.new()

      {cmd, _caches} = AgentContextEncoder.encode(model, caches)

      assert <<@op_gui_agent_context, 0::8, 0::16, _ts::64, 0::8, 0::8>> = cmd
    end

    test "encodes visible agent context" do
      ts = ~U[2024-01-15 10:30:00Z]

      model = %AgentContext{
        visible: true,
        task: "Fix build",
        dispatch_timestamp: ts,
        status: :working,
        can_approve: false
      }

      caches = Caches.new()
      {cmd, _caches} = AgentContextEncoder.encode(model, caches)

      task_len = byte_size("Fix build")
      timestamp_unix = DateTime.to_unix(ts)

      assert <<@op_gui_agent_context, 1::8, ^task_len::16, "Fix build", ^timestamp_unix::64, 1::8,
               0::8>> = cmd
    end

    test "encodes can_approve=true" do
      ts = ~U[2024-01-15 10:30:00Z]

      model = %AgentContext{
        visible: true,
        task: "Done",
        dispatch_timestamp: ts,
        status: :done,
        can_approve: true
      }

      caches = Caches.new()
      {cmd, _caches} = AgentContextEncoder.encode(model, caches)

      task_len = byte_size("Done")
      timestamp_unix = DateTime.to_unix(ts)

      assert <<@op_gui_agent_context, 1::8, ^task_len::16, "Done", ^timestamp_unix::64, 4::8,
               1::8>> = cmd
    end

    test "returns nil on second call with same model (fingerprint skip)" do
      model = %AgentContext{visible: false}
      caches = Caches.new()

      {cmd1, caches} = AgentContextEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = AgentContextEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when model changes" do
      model1 = %AgentContext{visible: false}

      model2 = %AgentContext{
        visible: true,
        task: "Test",
        dispatch_timestamp: ~U[2024-01-15 10:30:00Z],
        status: :idle,
        can_approve: false
      }

      caches = Caches.new()
      {_, caches} = AgentContextEncoder.encode(model1, caches)
      {cmd2, _caches} = AgentContextEncoder.encode(model2, caches)

      assert cmd2 != nil
    end
  end
end
