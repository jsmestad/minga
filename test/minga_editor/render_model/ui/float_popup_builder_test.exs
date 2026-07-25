defmodule MingaEditor.RenderModel.UI.FloatPopupBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Popup.Rule
  alias Minga.RenderModel.UI.FloatPopup
  alias MingaEditor.Observatory.Inspection
  alias MingaEditor.RenderModel.UI.FloatPopupBuilder
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
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
      inspection_data = %Inspection{
        visible: true,
        title: "Inspect",
        lines: ["line1"],
        width: 40,
        height: 20
      }

      shell_state = TraditionalState.inspect_observatory(%TraditionalState{}, inspection_data)
      ctx = build_minimal_context(shell_state)

      model = FloatPopupBuilder.build(ctx)

      assert %FloatPopup{} = model
      assert model.visible?
      assert model.title == "Inspect"
      assert model.lines == ["line1"]
      assert model.width == 40
      assert model.height == 20
    end

    test "hidden observatory inspection falls through to float window check" do
      inspection_data = %Inspection{visible: false, title: "", lines: [], width: 1, height: 1}
      shell_state = TraditionalState.inspect_observatory(%TraditionalState{}, inspection_data)
      ctx = build_minimal_context(shell_state)

      model = FloatPopupBuilder.build(ctx)

      refute model.visible?
    end

    test "builds float popup from window buffer using preferred size hints without trimming content" do
      ctx = build_minimal_context(%{})

      buffer =
        start_supervised!(
          {Minga.Buffer.Process, content: "abcdefghi\nsecond line\nthird", buffer_name: "*Float*"}
        )

      rule = Rule.new("*Float*", display: :float, width: {:cols, 8}, height: {:rows, 4})
      popup_meta = Active.new(rule, 1)
      popup_window = %{Window.new(2, buffer, 10, 80) | popup_meta: popup_meta}
      windows = %{ctx.windows | map: Map.put(ctx.windows.map, 2, popup_window)}
      ctx = %{ctx | windows: windows}

      model = FloatPopupBuilder.build(ctx)

      assert model.visible?
      assert model.title == "*Float*"
      assert model.width == 8
      assert model.height == 4
      assert model.lines == ["abcdefghi", "second line", "third"]
    end
  end

  defp build_minimal_context(shell_state) do
    state = gui_state()
    ctx = MingaEditor.Frontend.Emit.Context.from_editor_state(state)
    frame = %{ctx.intent.frame | shell_state: shell_state}
    %{ctx | intent: %{ctx.intent | frame: frame}}
  end
end
