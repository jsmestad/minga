defmodule MingaEditor.RenderModel.UI.ObservatoryBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.ObservatoryBuilder
  alias Minga.RenderModel.UI.Observatory
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Observatory.Data, as: ObservatoryData

  @op_gui_observatory Minga.Protocol.Opcodes.gui_observatory()

  describe "build/1" do
    test "builds hidden observatory when not visible" do
      shell_state = %{}

      model = ObservatoryBuilder.build(shell_state)

      assert %Observatory{visible: false, fingerprint: :hidden} = model
      assert is_binary(model.encoded)
      assert <<@op_gui_observatory, _rest::binary>> = model.encoded
    end

    test "builds hidden observatory when observatory_visible is false" do
      shell_state = %{observatory_visible: false}

      model = ObservatoryBuilder.build(shell_state)

      assert %Observatory{visible: false, fingerprint: :hidden} = model
    end

    test "builds visible observatory with data" do
      data = ObservatoryData.visible(nil, [])
      shell_state = %{observatory_visible: true, observatory_data: data}

      model = ObservatoryBuilder.build(shell_state)

      assert %Observatory{visible: true} = model
      assert is_integer(model.fingerprint)
      assert is_binary(model.encoded)
      assert <<@op_gui_observatory, _rest::binary>> = model.encoded
    end

    test "builds visible observatory with nil data (defaults to empty visible)" do
      shell_state = %{observatory_visible: true, observatory_data: nil}

      model = ObservatoryBuilder.build(shell_state)

      assert %Observatory{visible: true} = model
    end

    test "produces byte-identical output to legacy for hidden state" do
      legacy_binary = ProtocolGUI.encode_gui_observatory(ObservatoryData.hidden())

      model = ObservatoryBuilder.build(%{})

      assert model.encoded == legacy_binary,
             "Hidden observatory: new builder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for visible with nil data" do
      payload = ObservatoryData.visible(nil, [])
      legacy_binary = ProtocolGUI.encode_gui_observatory(payload)

      shell_state = %{observatory_visible: true, observatory_data: nil}
      model = ObservatoryBuilder.build(shell_state)

      assert model.encoded == legacy_binary,
             "Visible observatory with nil data: new builder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for visible with data" do
      data = ObservatoryData.visible(nil, [])
      legacy_binary = ProtocolGUI.encode_gui_observatory(data)

      shell_state = %{observatory_visible: true, observatory_data: data}
      model = ObservatoryBuilder.build(shell_state)

      assert model.encoded == legacy_binary,
             "Visible observatory with data: new builder output does not match legacy output"
    end
  end
end
