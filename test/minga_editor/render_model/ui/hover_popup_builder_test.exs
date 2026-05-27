defmodule MingaEditor.RenderModel.UI.HoverPopupBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.HoverPopupBuilder
  alias Minga.RenderModel.UI.HoverPopup
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  import MingaEditor.RenderPipeline.TestHelpers

  @op_gui_hover_popup Minga.Protocol.Opcodes.gui_hover_popup()

  describe "build/1" do
    test "builds nil hover popup when shell_state has no hover_popup" do
      ctx = build_minimal_context(%{})

      model = HoverPopupBuilder.build(ctx)

      assert %HoverPopup{} = model
      assert is_binary(model.encoded)
      assert is_integer(model.fingerprint)
      assert <<@op_gui_hover_popup, 0>> = model.encoded
    end

    test "builds nil hover popup (no shell_state hover_popup key)" do
      ctx = build_minimal_context(%{some_other_key: true})

      model = HoverPopupBuilder.build(ctx)

      assert %HoverPopup{} = model
      assert <<@op_gui_hover_popup, 0>> = model.encoded
    end

    test "produces byte-identical output to legacy for nil popup" do
      legacy_binary = ProtocolGUI.encode_gui_hover_popup(nil)

      ctx = build_minimal_context(%{})
      model = HoverPopupBuilder.build(ctx)

      assert model.encoded == legacy_binary,
             "Nil hover popup: new builder output does not match legacy output"
    end

    test "builds hover popup with actual popup data" do
      popup = %MingaEditor.HoverPopup{
        content_lines: [{[{"hello", :plain}], :text}],
        anchor_row: 5,
        anchor_col: 10,
        focused: false,
        scroll_offset: 0,
        open_action: nil
      }

      ctx = build_minimal_context(%{hover_popup: popup})

      model = HoverPopupBuilder.build(ctx)

      assert %HoverPopup{} = model
      assert <<@op_gui_hover_popup, 1, _rest::binary>> = model.encoded
    end

    test "produces byte-identical output to legacy for actual popup" do
      popup = %MingaEditor.HoverPopup{
        content_lines: [{[{"hello", :plain}], :text}],
        anchor_row: 5,
        anchor_col: 10,
        focused: false,
        scroll_offset: 0,
        open_action: nil
      }

      legacy_binary = ProtocolGUI.encode_gui_hover_popup(popup)

      ctx = build_minimal_context(%{hover_popup: popup})
      model = HoverPopupBuilder.build(ctx)

      assert model.encoded == legacy_binary,
             "Hover popup: new builder output does not match legacy output"
    end
  end

  defp build_minimal_context(shell_state) do
    state = gui_state()
    ctx = MingaEditor.Frontend.Emit.Context.from_editor_state(state)
    %{ctx | shell_state: shell_state}
  end
end
