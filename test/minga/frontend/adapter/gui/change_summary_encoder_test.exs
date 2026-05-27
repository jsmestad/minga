defmodule Minga.Frontend.Adapter.GUI.ChangeSummaryEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ChangeSummaryEncoder
  alias Minga.RenderModel.UI.ChangeSummary

  @op_gui_change_summary Minga.Protocol.Opcodes.gui_change_summary()

  describe "encode/2" do
    test "encodes hidden change summary" do
      model = %ChangeSummary{
        encoded: <<@op_gui_change_summary, 0::16, 0::16>>,
        fingerprint: :hidden
      }

      caches = Caches.new()

      {cmd, _caches} = ChangeSummaryEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %ChangeSummary{
        encoded: <<@op_gui_change_summary, 0::16, 0::16>>,
        fingerprint: :hidden
      }

      caches = Caches.new()

      {cmd1, caches} = ChangeSummaryEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = ChangeSummaryEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %ChangeSummary{
        encoded: <<@op_gui_change_summary, 0::16, 0::16>>,
        fingerprint: :hidden
      }

      model2 = %ChangeSummary{
        encoded: <<@op_gui_change_summary, 1::16, "data">>,
        fingerprint: 99999
      }

      caches = Caches.new()
      {_, caches} = ChangeSummaryEncoder.encode(model1, caches)
      {cmd2, _caches} = ChangeSummaryEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end
  end
end
