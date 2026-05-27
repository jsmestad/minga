defmodule MingaEditor.RenderModel.UI.SidebarsBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.SidebarsBuilder
  alias Minga.RenderModel.UI.Sidebars

  @op_gui_sidebars Minga.Protocol.Opcodes.gui_sidebars()

  describe "build/1" do
    test "builds sidebars model from context with default sidebar registry" do
      ctx = build_minimal_context()
      model = SidebarsBuilder.build(ctx)

      assert %Sidebars{} = model
      assert is_binary(model.encoded)
      assert is_integer(model.fingerprint)
      assert <<@op_gui_sidebars, _payload_len::32, _payload::binary>> = model.encoded
    end

    test "fingerprint is consistent for same sidebar state" do
      ctx = build_minimal_context()
      model1 = SidebarsBuilder.build(ctx)
      model2 = SidebarsBuilder.build(ctx)

      assert model1.fingerprint == model2.fingerprint
    end
  end

  defp build_minimal_context do
    %MingaEditor.Frontend.Emit.Context{
      port_manager: self(),
      capabilities: MingaEditor.Frontend.Capabilities.default(),
      theme: MingaEditor.UI.Theme.get!(:doom_one),
      font_registry: MingaEditor.UI.FontRegistry.new(),
      windows: %MingaEditor.State.Windows{map: %{}, active: 1},
      layout: %MingaEditor.Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 0, 80, 24},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{}
      },
      shell: MingaEditor.Shell.Traditional,
      shell_state: %{}
    }
  end
end
