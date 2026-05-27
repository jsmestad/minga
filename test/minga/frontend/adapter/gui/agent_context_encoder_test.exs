defmodule Minga.Frontend.Adapter.GUI.AgentContextEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.AgentContextEncoder
  alias Minga.RenderModel.UI.AgentContext
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

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

      assert <<@op_gui_agent_context, 1::8, ^task_len::16, "Fix build", ^timestamp_unix::64,
               1::8, 0::8>> = cmd
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

    test "produces byte-identical output to legacy ProtocolGUI for visible agent context" do
      ts = ~U[2024-01-15 10:30:00Z]
      task = "Fix the broken tests"
      status = :working
      can_approve = false

      legacy_binary = ProtocolGUI.encode_gui_agent_context(true, task, ts, status, can_approve)

      model = %AgentContext{
        visible: true,
        task: task,
        dispatch_timestamp: ts,
        status: status,
        can_approve: can_approve
      }

      caches = Caches.new()
      {new_binary, _caches} = AgentContextEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "Visible agent context: new encoder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for needs_you with can_approve" do
      ts = ~U[2024-06-01 12:00:00Z]
      task = "Review my changes"
      status = :needs_you
      can_approve = true

      legacy_binary = ProtocolGUI.encode_gui_agent_context(true, task, ts, status, can_approve)

      model = %AgentContext{
        visible: true,
        task: task,
        dispatch_timestamp: ts,
        status: status,
        can_approve: can_approve
      }

      caches = Caches.new()
      {new_binary, _caches} = AgentContextEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "needs_you agent context: new encoder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for done with can_approve" do
      ts = ~U[2024-03-20 08:15:00Z]
      task = "Completed task"
      status = :done
      can_approve = true

      legacy_binary = ProtocolGUI.encode_gui_agent_context(true, task, ts, status, can_approve)

      model = %AgentContext{
        visible: true,
        task: task,
        dispatch_timestamp: ts,
        status: status,
        can_approve: can_approve
      }

      caches = Caches.new()
      {new_binary, _caches} = AgentContextEncoder.encode(model, caches)

      assert new_binary == legacy_binary
    end

    test "produces byte-identical output to legacy for all status types" do
      ts = ~U[2024-01-01 00:00:00Z]

      for status <- [:idle, :working, :iterating, :needs_you, :done, :errored] do
        can_approve = status in [:needs_you, :done]
        legacy_binary = ProtocolGUI.encode_gui_agent_context(true, "task", ts, status, can_approve)

        model = %AgentContext{
          visible: true,
          task: "task",
          dispatch_timestamp: ts,
          status: status,
          can_approve: can_approve
        }

        caches = Caches.new()
        {new_binary, _caches} = AgentContextEncoder.encode(model, caches)

        assert new_binary == legacy_binary,
               "Status #{status}: new encoder output does not match legacy output"
      end
    end

    test "produces byte-identical output to legacy for empty task string" do
      ts = ~U[2024-01-01 00:00:00Z]
      legacy_binary = ProtocolGUI.encode_gui_agent_context(true, "", ts, :idle, false)

      model = %AgentContext{
        visible: true,
        task: "",
        dispatch_timestamp: ts,
        status: :idle,
        can_approve: false
      }

      caches = Caches.new()
      {new_binary, _caches} = AgentContextEncoder.encode(model, caches)

      assert new_binary == legacy_binary
    end
  end
end
