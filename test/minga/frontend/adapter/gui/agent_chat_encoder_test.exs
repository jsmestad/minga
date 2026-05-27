defmodule Minga.Frontend.Adapter.GUI.AgentChatEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.AgentChatEncoder
  alias Minga.RenderModel.UI.AgentChat

  @op_gui_agent_chat Minga.Protocol.Opcodes.gui_agent_chat()

  describe "encode/2" do
    test "encodes not_visible agent chat" do
      model = %AgentChat{
        encoded: <<@op_gui_agent_chat, 0::8>>,
        fingerprint: :not_visible
      }

      caches = Caches.new()

      {cmd, _caches} = AgentChatEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "encodes visible agent chat" do
      model = %AgentChat{
        encoded: <<@op_gui_agent_chat, 1::8, "chat_data">>,
        fingerprint: 54_321
      }

      caches = Caches.new()

      {cmd, _caches} = AgentChatEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %AgentChat{
        encoded: <<@op_gui_agent_chat, 0::8>>,
        fingerprint: :not_visible
      }

      caches = Caches.new()

      {cmd1, caches} = AgentChatEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = AgentChatEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %AgentChat{
        encoded: <<@op_gui_agent_chat, 0::8>>,
        fingerprint: :not_visible
      }

      model2 = %AgentChat{
        encoded: <<@op_gui_agent_chat, 1::8, "data!">>,
        fingerprint: 99_999
      }

      caches = Caches.new()
      {_, caches} = AgentChatEncoder.encode(model1, caches)
      {cmd2, _caches} = AgentChatEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end

    test "transitions from visible to not_visible" do
      visible_model = %AgentChat{
        encoded: <<@op_gui_agent_chat, 1::8, "data!">>,
        fingerprint: 12_345
      }

      hidden_model = %AgentChat{
        encoded: <<@op_gui_agent_chat, 0::8>>,
        fingerprint: :not_visible
      }

      caches = Caches.new()
      {_, caches} = AgentChatEncoder.encode(visible_model, caches)
      {cmd, _caches} = AgentChatEncoder.encode(hidden_model, caches)

      assert cmd == hidden_model.encoded
    end
  end
end
