defmodule MingaEditor.RenderModel.UI.FloatPopupBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.FloatPopupBuilder
  alias Minga.RenderModel.UI.FloatPopup
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  import MingaEditor.RenderPipeline.TestHelpers

  @op_gui_float_popup Minga.Protocol.Opcodes.gui_float_popup()

  describe "build/1" do
    test "builds hidden float popup when no float window or observatory inspection" do
      ctx = build_minimal_context(%{})

      model = FloatPopupBuilder.build(ctx)

      assert %FloatPopup{} = model
      assert is_binary(model.encoded)
      assert is_integer(model.fingerprint)
      assert <<@op_gui_float_popup, 0>> = model.encoded
    end

    test "produces byte-identical output to legacy for hidden float popup" do
      legacy_binary = ProtocolGUI.encode_gui_float_popup(%{
        visible: false,
        title: "",
        lines: [],
        width: 0,
        height: 0
      })

      ctx = build_minimal_context(%{})
      model = FloatPopupBuilder.build(ctx)

      assert model.encoded == legacy_binary,
             "Hidden float popup: new builder output does not match legacy output"
    end

    test "builds observatory inspection float popup" do
      inspection_data = %{visible: true, title: "Inspect", lines: ["line1"], width: 40, height: 20}
      ctx = build_minimal_context(%{observatory_inspection: inspection_data})

      model = FloatPopupBuilder.build(ctx)

      assert %FloatPopup{} = model
      assert <<@op_gui_float_popup, 1, _rest::binary>> = model.encoded
    end

    test "produces byte-identical output to legacy for observatory inspection" do
      inspection_data = %{visible: true, title: "Inspect", lines: ["line1"], width: 40, height: 20}
      legacy_binary = ProtocolGUI.encode_gui_float_popup(inspection_data)

      ctx = build_minimal_context(%{observatory_inspection: inspection_data})
      model = FloatPopupBuilder.build(ctx)

      assert model.encoded == legacy_binary,
             "Observatory inspection: new builder output does not match legacy output"
    end

    test "hidden observatory inspection falls through to float window check" do
      inspection_data = %{visible: false}
      ctx = build_minimal_context(%{observatory_inspection: inspection_data})

      model = FloatPopupBuilder.build(ctx)

      # No float window exists in minimal context, so it should be hidden
      assert %FloatPopup{} = model
      assert <<@op_gui_float_popup, 0>> = model.encoded
    end
  end

  defp build_minimal_context(shell_state) do
    state = gui_state()
    ctx = MingaEditor.Frontend.Emit.Context.from_editor_state(state)
    %{ctx | shell_state: shell_state}
  end
end
