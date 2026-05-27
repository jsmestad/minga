defmodule MingaEditor.RenderModel.UI.TabBarBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.TabBarBuilder
  alias Minga.RenderModel.UI.TabBar

  describe "build/1" do
    test "returns suppressed tab bar when shell has no gui_payload" do
      ctx = build_minimal_context()
      model = TabBarBuilder.build(ctx)

      assert %TabBar{encoded: nil, fingerprint: :suppressed} = model
    end

    test "returns suppressed tab bar when tab_bar state is nil" do
      ctx = build_minimal_context(tab_bar: nil)
      model = TabBarBuilder.build(ctx)

      assert %TabBar{encoded: nil, fingerprint: :suppressed} = model
    end
  end

  defp build_minimal_context(opts \\ []) do
    tab_bar = Keyword.get(opts, :tab_bar, nil)

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
      shell_state: %{tab_bar: tab_bar}
    }
  end
end
