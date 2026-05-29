defmodule MingaEditor.RenderModel.UI.ExtensionOverlayBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.ExtensionOverlay
  alias MingaEditor.RenderModel.UI.ExtensionOverlayBuilder

  import MingaEditor.RenderPipeline.TestHelpers

  describe "build/1" do
    test "builds extension overlay model with no overlays" do
      ctx = build_minimal_context()

      model = ExtensionOverlayBuilder.build(ctx)

      assert %ExtensionOverlay{} = model
      assert model.entries == []
    end
  end

  defp build_minimal_context do
    state = gui_state()
    MingaEditor.Frontend.Emit.Context.from_editor_state(state)
  end
end
