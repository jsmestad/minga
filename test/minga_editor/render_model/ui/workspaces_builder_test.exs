defmodule MingaEditor.RenderModel.UI.WorkspacesBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Workspaces
  alias MingaEditor.RenderModel.UI.WorkspacesBuilder

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
      shell_state: shell_state
    }
  end
end
