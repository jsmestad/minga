defmodule Minga.Frontend.Adapter.GUI.ObservatoryEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ObservatoryEncoder
  alias Minga.RenderModel.UI.Observatory

  @op_gui_observatory Minga.Protocol.Opcodes.gui_observatory()

  describe "encode/2" do
    test "encodes hidden observatory" do
      model = %Observatory{
        visible: false,
        encoded: <<@op_gui_observatory, 0::32, "hidden">>,
        fingerprint: :hidden
      }

      caches = Caches.new()

      {cmd, _caches} = ObservatoryEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "encodes visible observatory" do
      model = %Observatory{
        visible: true,
        encoded: <<@op_gui_observatory, 10::32, "visible_data">>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd, _caches} = ObservatoryEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %Observatory{
        visible: false,
        encoded: <<@op_gui_observatory, 0::32>>,
        fingerprint: :hidden
      }

      caches = Caches.new()

      {cmd1, caches} = ObservatoryEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = ObservatoryEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %Observatory{
        visible: false,
        encoded: <<@op_gui_observatory, 0::32>>,
        fingerprint: :hidden
      }

      model2 = %Observatory{
        visible: true,
        encoded: <<@op_gui_observatory, 5::32, "data!">>,
        fingerprint: 99999
      }

      caches = Caches.new()
      {_, caches} = ObservatoryEncoder.encode(model1, caches)
      {cmd2, _caches} = ObservatoryEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end

    test "transitions from visible to hidden" do
      visible_model = %Observatory{
        visible: true,
        encoded: <<@op_gui_observatory, 5::32, "data!">>,
        fingerprint: 12345
      }

      hidden_model = %Observatory{
        visible: false,
        encoded: <<@op_gui_observatory, 0::32>>,
        fingerprint: :hidden
      }

      caches = Caches.new()
      {_, caches} = ObservatoryEncoder.encode(visible_model, caches)
      {cmd, _caches} = ObservatoryEncoder.encode(hidden_model, caches)

      assert cmd == hidden_model.encoded
    end
  end
end
