defmodule MingaEditor.RenderModel.UI.WorkspacesBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Workspaces
  alias MingaEditor.RenderModel.UI.WorkspacesBuilder
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.TestHelpers

  describe "build/1" do
    test "returns hidden workspaces when tab_bar is nil" do
      ctx = build_minimal_context(tab_bar: nil)
      model = WorkspacesBuilder.build(ctx)

      assert %Workspaces{visible?: false, workspaces: [], visible_tabs: []} = model
    end

    test "returns hidden workspaces when shell_state has no tab_bar key" do
      ctx = build_minimal_context(shell_state: %{})
      model = WorkspacesBuilder.build(ctx)

      assert %Workspaces{visible?: false, workspaces: [], visible_tabs: []} = model
    end
  end

  defp build_minimal_context(opts) do
    tab_bar = Keyword.get(opts, :tab_bar, nil)
    shell_state = Keyword.get(opts, :shell_state, %{tab_bar: tab_bar})

    ctx =
      TestHelpers.base_state(port_manager: nil)
      |> Context.from_editor_state()

    frame = %{ctx.intent.frame | shell_state: shell_state}
    %{ctx | intent: %{ctx.intent | frame: frame}, tab_bar: Map.get(shell_state, :tab_bar)}
  end
end
