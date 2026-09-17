defmodule MingaEditor.RenderModel.Window.ResidentBuildTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.Window.ResidentBuild
  alias MingaEditor.UI.FontRegistry

  test "hydration rejects ranged and incomplete sources before composition" do
    for source <- [{:range, 0, ["visible"]}, {:range, 120, ["visible"]}, {:complete, ["visible"]}] do
      inputs = %{
        source: source,
        plan: {:hydrate, :composition_context},
        line_count: 300,
        compose_fp: 1,
        highlight_fp: nil,
        reset?: false,
        hydration_reason: nil,
        keyframe?: false,
        retained_rows: %{},
        edit_deltas: [],
        font_registry: FontRegistry.new(),
        build_all: fn _ -> flunk("must reject incomplete source before composition") end,
        build_dirty: fn _, _ -> flunk("hydration must not enter the splice path") end
      }

      assert_raise ArgumentError,
                   "resident hydration requires a complete source from line zero",
                   fn ->
                     ResidentBuild.run(nil, inputs)
                   end
    end
  end

  test "splice plans reject source that does not cover the changed lines" do
    for plan <- [{:splice, 50, 1, 3}, {:splices, [49, 51]}] do
      assert_raise ArgumentError, "resident splice source does not cover inserted rows", fn ->
        ResidentBuild.run(nil, %{
          source: {:range, 50, ["only one line"]},
          plan: plan,
          keyframe?: false
        })
      end
    end
  end
end
