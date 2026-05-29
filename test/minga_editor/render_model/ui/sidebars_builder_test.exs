defmodule MingaEditor.RenderModel.UI.SidebarsBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Sidebars
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.RenderModel.UI.SidebarsBuilder

  describe "build/1" do
    test "builds semantic sidebars model from context with default sidebar registry" do
      sidebar_registry = start_sidebar_registry()
      ctx = build_minimal_context(sidebar_registry)
      model = SidebarsBuilder.build(ctx)

      assert %Sidebars{} = model
      assert model.active_id == ""
      assert model.sidebars == []
    end

    test "selects active visible sidebar and normalizes focus" do
      sidebar_registry = start_sidebar_registry()

      assert :ok =
               Sidebar.register(sidebar_registry, {:extension, :alpha}, %{
                 id: "outline",
                 display_name: "Outline",
                 priority: 10,
                 visible?: true,
                 focused?: false,
                 badge_count: nil,
                 snapshot: [rows: [%{id: "a", badge: "!"}]]
               })

      assert :ok =
               Sidebar.register(sidebar_registry, {:extension, :beta}, %{
                 id: "bookmarks",
                 display_name: "Bookmarks",
                 priority: 20,
                 visible?: true,
                 focused?: true
               })

      ctx = build_minimal_context(sidebar_registry)
      model = SidebarsBuilder.build(ctx)

      assert model.active_id == "bookmarks"

      assert Enum.map(model.sidebars, &{&1.id, &1.focused?, &1.badge_count}) == [
               {"outline", false, 1},
               {"bookmarks", true, nil}
             ]
    end

    test "semantic model is consistent for same sidebar state" do
      sidebar_registry = start_sidebar_registry()
      ctx = build_minimal_context(sidebar_registry)
      model1 = SidebarsBuilder.build(ctx)
      model2 = SidebarsBuilder.build(ctx)

      assert model1 == model2
    end
  end

  defp build_minimal_context(sidebar_registry) do
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
      shell_state: %{},
      sidebar_registry: sidebar_registry
    }
  end

  defp start_sidebar_registry do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    table
  end
end
