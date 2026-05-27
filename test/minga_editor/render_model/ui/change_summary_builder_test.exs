defmodule MingaEditor.RenderModel.UI.ChangeSummaryBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.ChangeSummaryBuilder
  alias Minga.RenderModel.UI.ChangeSummary
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_change_summary Minga.Protocol.Opcodes.gui_change_summary()

  describe "build/1" do
    test "builds hidden change summary when payload is nil" do
      model = ChangeSummaryBuilder.build(nil)

      assert %ChangeSummary{fingerprint: :hidden} = model
      assert is_binary(model.encoded)
      assert <<@op_gui_change_summary, _rest::binary>> = model.encoded
    end

    test "builds hidden change summary when payload is not a board" do
      model = ChangeSummaryBuilder.build({:other, %{}})

      assert %ChangeSummary{fingerprint: :hidden} = model
    end

    test "builds hidden change summary when board has no zoomed card" do
      model = ChangeSummaryBuilder.build({:board, %{zoomed_card_id: nil}})

      assert %ChangeSummary{fingerprint: :hidden} = model
    end

    test "builds active change summary for zoomed board card" do
      model = ChangeSummaryBuilder.build({:board, %{zoomed_card_id: 42}})

      assert %ChangeSummary{} = model
      assert is_integer(model.fingerprint)
      assert is_binary(model.encoded)
      assert <<@op_gui_change_summary, _rest::binary>> = model.encoded
    end

    test "produces byte-identical output to legacy for hidden state" do
      legacy_binary = ProtocolGUI.encode_gui_change_summary([], 0)

      model = ChangeSummaryBuilder.build(nil)

      assert model.encoded == legacy_binary,
             "Hidden change summary: new builder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for zoomed card" do
      legacy_binary = ProtocolGUI.encode_gui_change_summary([], 0)

      model = ChangeSummaryBuilder.build({:board, %{zoomed_card_id: 42}})

      assert model.encoded == legacy_binary,
             "Zoomed card change summary: new builder output does not match legacy output"
    end

    test "fingerprint changes when card_id changes" do
      model1 = ChangeSummaryBuilder.build({:board, %{zoomed_card_id: 1}})
      model2 = ChangeSummaryBuilder.build({:board, %{zoomed_card_id: 2}})

      assert model1.fingerprint != model2.fingerprint
    end
  end
end
