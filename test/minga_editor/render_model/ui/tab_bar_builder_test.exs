defmodule MingaEditor.RenderModel.UI.TabBarBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.TabBar
  alias MingaEditor.RenderModel.UI.TabBarBuilder
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State.TabBar, as: TabBarState

  describe "build/1" do
    test "returns hidden tab bar when shell has no gui_payload" do
      ctx = build_minimal_context()
      model = TabBarBuilder.build(ctx)

      assert %TabBar{visible?: false, active_tab_id: nil, tabs: []} = model
    end

    test "returns hidden tab bar when tab_bar state is nil" do
      ctx = build_minimal_context(tab_bar: nil)
      model = TabBarBuilder.build(ctx)

      assert %TabBar{visible?: false, active_tab_id: nil, tabs: []} = model
    end

    test "empty TabBar projects nil active tab and no tab models" do
      ctx = build_minimal_context(tab_bar: TabBarState.new_empty("/tmp/project"))
      model = TabBarBuilder.build(ctx)

      assert %TabBar{visible?: true, active_tab_id: nil, tabs: []} = model
    end
  end

  defp build_minimal_context(opts \\ []) do
    tab_bar = Keyword.get(opts, :tab_bar, nil)

    ctx =
      TestHelpers.base_state(port_manager: nil)
      |> Context.from_editor_state()

    frame = %{ctx.intent.frame | shell_state: %{tab_bar: tab_bar}}
    %{ctx | intent: %{ctx.intent | frame: frame}, tab_bar: tab_bar}
  end
end
