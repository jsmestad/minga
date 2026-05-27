defmodule Minga.Frontend.Adapter.GUI.PickerEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.RenderModel.UI.Picker

  @op_gui_picker Minga.Protocol.Opcodes.gui_picker()

  describe "encode/2" do
    test "encodes closed picker" do
      model = %Picker{
        encoded: <<@op_gui_picker, 0::8, "closed">>,
        fingerprint: :closed
      }

      caches = Caches.new()

      {cmd, _caches} = PickerEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "encodes open picker" do
      model = %Picker{
        encoded: <<@op_gui_picker, 1::8, "picker_data">>,
        fingerprint: 54_321
      }

      caches = Caches.new()

      {cmd, _caches} = PickerEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %Picker{
        encoded: <<@op_gui_picker, 0::8>>,
        fingerprint: :closed
      }

      caches = Caches.new()

      {cmd1, caches} = PickerEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = PickerEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %Picker{
        encoded: <<@op_gui_picker, 0::8>>,
        fingerprint: :closed
      }

      model2 = %Picker{
        encoded: <<@op_gui_picker, 1::8, "data!">>,
        fingerprint: 99_999
      }

      caches = Caches.new()
      {_, caches} = PickerEncoder.encode(model1, caches)
      {cmd2, _caches} = PickerEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end

    test "transitions from open to closed" do
      open_model = %Picker{
        encoded: <<@op_gui_picker, 1::8, "data!">>,
        fingerprint: 12_345
      }

      closed_model = %Picker{
        encoded: <<@op_gui_picker, 0::8>>,
        fingerprint: :closed
      }

      caches = Caches.new()
      {_, caches} = PickerEncoder.encode(open_model, caches)
      {cmd, _caches} = PickerEncoder.encode(closed_model, caches)

      assert cmd == closed_model.encoded
    end
  end
end
