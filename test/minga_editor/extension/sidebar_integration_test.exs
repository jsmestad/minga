defmodule MingaEditor.Extension.SidebarIntegrationTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FocusTree
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Input.Router
  alias MingaEditor.Layout
  alias MingaEditor.RenderModel.UI.SidebarsBuilder
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    %{sidebar_registry: table}
  end

  # The Traditional shell no longer reserves BEAM columns for the sidebar; every
  # live frontend renders it natively (the legacy Zig cell-grid frontend, and its
  # `Layout.TUI`/`SidebarRenderer` cell renderers, were retired in #2223/#2235).
  # These tests assert the surviving semantic equivalents: the sidebar registry
  # state, the `SidebarsBuilder` metadata the frontend reads, and the FocusTree
  # input routing that turns a sidebar rect into editor input.

  test "a visible registered sidebar is emitted with its width and reclaimed when hidden", %{
    sidebar_registry: table
  } do
    state = gui_state(cols: 80, rows: 24, sidebar_registry: table)

    refute visible_sidebar(state, "outline")

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true
             })

    entry = visible_sidebar(state, "outline")
    assert entry.visible?
    assert entry.preferred_width == 25
    assert SidebarsBuilder.build(Context.from_editor_state(state)).active_id == "outline"

    assert :ok = Sidebar.set_visible(table, {:extension, :outline}, "outline", false)
    refute visible_sidebar(state, "outline")
    assert SidebarsBuilder.build(Context.from_editor_state(state)).active_id == ""
  end

  test "focus tree routes a registered sidebar rect to the generic sidebar handler", %{
    sidebar_registry: table
  } do
    state = gui_state(cols: 80, rows: 24, sidebar_registry: table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true,
               focused?: true
             })

    state = %{state | layout: sidebar_layout(state, {1, 0, 25, 21})}
    node = state |> FocusTree.from_state() |> FocusTree.hit_test(2, 2)

    assert node.content_type == {:custom, :sidebar}
    assert node.ref == "outline"
    assert node.handler == MingaEditor.Input.Sidebar
  end

  test "mouse input routes local coordinates through the generic sidebar handler", %{
    sidebar_registry: table
  } do
    state = gui_state(cols: 80, rows: 24, sidebar_registry: table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true,
               focused?: true,
               action_handler: fn state, "mouse", context ->
                 EditorState.set_status(
                   state,
                   "mouse #{context.row}:#{context.col}:#{context.button}:#{context.modifiers}:#{context.event_type}:#{context.click_count}"
                 )
               end
             })

    state = %{state | layout: sidebar_layout(state, {1, 0, 25, 21})}
    focus_tree = FocusTree.from_state(state)

    new_state =
      Router.dispatch_mouse(%{state | focus_tree: focus_tree}, 2, 3, :left, 4, :press, 2)

    assert EditorState.status_msg(new_state) == "mouse 1:3:left:4:press:2"
  end

  test "keyboard input routes through the generic sidebar handler when focused", %{
    sidebar_registry: table
  } do
    state = base_state(cols: 80, rows: 24, sidebar_registry: table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true,
               focused?: true,
               action_handler: fn state, "key", %{codepoint: ?j} ->
                 EditorState.set_status(state, "sidebar key handled")
               end
             })

    new_state = Router.dispatch(state, ?j, 0)
    assert EditorState.status_msg(new_state) == "sidebar key handled"
  end

  test "snapshot updates can notify an explicit render target" do
    table = Module.concat(__MODULE__, "NotifySidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: self()})

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               visible?: true
             })

    flush_sidebar_messages(table)

    assert :ok =
             Sidebar.publish_snapshot(table, {:extension, :outline}, "outline",
               rows: [%{id: "a", text: "alpha"}]
             )

    assert_receive {:sidebar_changed, ^table}
  end

  test "snapshot rows feed the semantic sidebar metadata", %{sidebar_registry: table} do
    state = gui_state(cols: 80, rows: 24, sidebar_registry: table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true,
               focused?: true,
               snapshot: [
                 rows: [
                   %{id: "a", text: "alpha", icon: "λ", indent: 0, badge: "!"},
                   %{id: "b", text: "beta", indent: 1, selected?: true}
                 ]
               ]
             })

    %{sidebars: sidebars, active_id: active_id} =
      SidebarsBuilder.build(Context.from_editor_state(state))

    assert active_id == "outline"

    outline = Enum.find(sidebars, &(&1.id == "outline"))
    assert outline.display_name == "Outline"
    assert outline.visible?
    # The badge in the snapshot rows is reflected in the emitted metadata.
    assert outline.badge_count == 1
  end

  test "non-built-in sidebar semantic kinds do not trigger built-in renderers", %{
    sidebar_registry: table
  } do
    state = gui_state(cols: 80, rows: 24, sidebar_registry: table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true,
               focused?: true,
               semantic_kind: "file_tree",
               snapshot: [rows: [%{id: "a", text: "alpha"}]]
             })

    %{sidebars: sidebars} = SidebarsBuilder.build(Context.from_editor_state(state))

    outline = Enum.find(sidebars, &(&1.id == "outline"))
    # The extension keeps its own id; it is not coerced into the built-in file_tree surface.
    assert outline.id == "outline"
    assert outline.semantic_kind == "file_tree"
    assert outline.display_name == "Outline"
  end

  # Drives the live FocusTree sidebar routing with an explicit sidebar rect. The
  # semantic `Layout.GUI` reserves no columns, so the rect is supplied directly;
  # the routing code under test is frontend-agnostic.
  defp sidebar_layout(state, file_tree_rect) do
    %Layout{} = base_layout = Layout.GUI.compute(state)
    %Layout{base_layout | file_tree: file_tree_rect}
  end

  defp visible_sidebar(state, id) do
    state
    |> Sidebar.table_for()
    |> Sidebar.all()
    |> Enum.find(fn sidebar -> sidebar.id == id and sidebar.visible? end)
  end

  defp flush_sidebar_messages(table) do
    receive do
      {:sidebar_changed, ^table} -> flush_sidebar_messages(table)
    after
      0 -> :ok
    end
  end
end
