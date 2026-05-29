defmodule MingaEditor.RenderModel.UI.FloatPopupBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Popup.Rule
  alias Minga.RenderModel.UI.FloatPopup
  alias MingaEditor.RenderModel.UI.FloatPopupBuilder
  alias MingaEditor.UI.Popup.Active
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  describe "build/1" do
    test "builds hidden float popup when no float window or observatory inspection exists" do
      ctx = build_minimal_context(%{})

      model = FloatPopupBuilder.build(ctx)

      assert %FloatPopup{} = model
      refute model.visible?
      assert model.lines == []
    end

    test "builds observatory inspection float popup" do
      inspection_data = %{
        visible: true,
        title: "Inspect",
        lines: ["line1"],
        width: 40,
        height: 20
      }

      ctx = build_minimal_context(%{observatory_inspection: inspection_data})

      model = FloatPopupBuilder.build(ctx)

      assert %FloatPopup{} = model
      assert model.visible?
      assert model.title == "Inspect"
      assert model.lines == ["line1"]
      assert model.width == 40
      assert model.height == 20
    end

    test "hidden observatory inspection falls through to float window check" do
      inspection_data = %{visible: false}
      ctx = build_minimal_context(%{observatory_inspection: inspection_data})

      model = FloatPopupBuilder.build(ctx)

      refute model.visible?
    end

    test "builds float popup from window buffer using resolved interior dimensions" do
      ctx = build_minimal_context(%{})

      buffer =
        start_supervised!(
          {Minga.Buffer.Process, content: "abcdefghi\nsecond line\nthird", buffer_name: "*Float*"}
        )

      rule = Rule.new("*Float*", display: :float, width: {:cols, 8}, height: {:rows, 4})
      popup_meta = Active.new(rule, 2, 1)
      popup_window = %{Window.new(2, buffer, 10, 80) | popup_meta: popup_meta}
      windows = %{ctx.windows | map: Map.put(ctx.windows.map, 2, popup_window)}
      ctx = %{ctx | windows: windows}

      model = FloatPopupBuilder.build(ctx)

      assert model.visible?
      assert model.title == "*Float*"
      assert model.width == 8
      assert model.height == 4
      assert model.lines == ["abcdef", "second"]
    end
  end

  defp build_minimal_context(shell_state) do
    state = gui_state()
    ctx = MingaEditor.Frontend.Emit.Context.from_editor_state(state)
    %{ctx | shell_state: shell_state}
  end
end
