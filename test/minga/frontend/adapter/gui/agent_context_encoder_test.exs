defmodule Minga.Frontend.Adapter.GUI.AgentContextEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.AgentContextEncoder
  alias Minga.RenderModel.UI.AgentContext
  alias Minga.RenderModel.UI.AgentContext.Progress
  alias Minga.RenderModel.UI.AgentContext.Todo

  @op_gui_agent_context Minga.Protocol.Opcodes.gui_agent_context()

  describe "encode/2" do
    test "encodes hidden agent context" do
      model = %AgentContext{visible: false}
      caches = Caches.new()

      {cmd, _caches} = AgentContextEncoder.encode(model, caches)

      assert <<@op_gui_agent_context, payload_len::16, payload::binary-size(payload_len)>> = cmd
      assert <<0::8, 0::16, _ts::64, 0::8, 0::8>> = payload
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

      assert <<@op_gui_agent_context, payload_len::16, payload::binary-size(payload_len)>> = cmd

      assert <<1::8, ^task_len::16, "Fix build", ^timestamp_unix::64, 1::8, 0::8,
               _progress_and_todos::binary>> = payload
    end

    test "encodes can_approve=true" do
      ts = ~U[2024-01-15 10:30:00Z]

      model = %AgentContext{
        visible: true,
        task: "Done",
        dispatch_timestamp: ts,
        status: :needs_you,
        can_approve: true
      }

      caches = Caches.new()
      {cmd, _caches} = AgentContextEncoder.encode(model, caches)

      task_len = byte_size("Done")
      timestamp_unix = DateTime.to_unix(ts)

      assert <<@op_gui_agent_context, payload_len::16, payload::binary-size(payload_len)>> = cmd

      assert <<1::8, ^task_len::16, "Done", ^timestamp_unix::64, 3::8, 1::8,
               _progress_and_todos::binary>> = payload
    end

    test "encodes progress and todo plan in the payload envelope" do
      ts = ~U[2024-01-15 10:30:00Z]

      model = %AgentContext{
        visible: true,
        task: "Done",
        dispatch_timestamp: ts,
        status: :needs_you,
        can_approve: true,
        progress: %Progress{
          active_action: "shell",
          tool_count: 2,
          file_count: 1,
          review_hint: "Review: approve or reject changes"
        },
        todos: [
          %Todo{description: "Inspect files", status: :done},
          %Todo{description: "Run tests", status: :in_progress}
        ]
      }

      {cmd, _caches} = AgentContextEncoder.encode(model, Caches.new())
      assert <<@op_gui_agent_context, payload_len::16, payload::binary-size(payload_len)>> = cmd

      task_len = byte_size("Done")
      timestamp_unix = DateTime.to_unix(ts)

      assert <<1::8, ^task_len::16, "Done", ^timestamp_unix::64, 3::8, 1::8, 5::16, "shell",
               2::16, 1::16, 33::16, "Review: approve or reject changes", 2::8, 2::8, 13::16,
               "Inspect files", 1::8, 9::16, "Run tests">> = payload
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
