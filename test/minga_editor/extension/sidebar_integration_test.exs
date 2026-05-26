defmodule MingaEditor.Extension.SidebarIntegrationTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FocusTree
  alias MingaEditor.Input.Router
  alias MingaEditor.Shell.Traditional.Layout.TUI, as: LayoutTUI
  alias MingaEditor.Shell.Traditional.SidebarRenderer
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    %{sidebar_registry: table}
  end

  test "layout reserves and reclaims space for a visible registered sidebar", %{
    sidebar_registry: table
  } do
    state = base_state(cols: 80, rows: 24, sidebar_registry: table)

    assert LayoutTUI.compute(state).file_tree == nil

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true
             })

    layout = LayoutTUI.compute(state)
    assert {1, 0, 25, 21} = layout.file_tree
    assert {1, 26, 54, 21} = layout.editor_area

    assert :ok = Sidebar.set_visible(table, {:extension, :outline}, "outline", false)
    assert LayoutTUI.compute(state).file_tree == nil
  end

  test "tiny terminals collapse registered sidebars instead of invalid editor dimensions", %{
    sidebar_registry: table
  } do
    state = base_state(cols: 12, rows: 8, sidebar_registry: table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 30,
               visible?: true
             })

    layout = LayoutTUI.compute(state)
    assert layout.file_tree == nil
    assert elem(layout.editor_area, 2) >= 1
    assert elem(layout.editor_area, 3) >= 1
  end

  test "focus tree routes registered sidebars to the generic sidebar handler", %{
    sidebar_registry: table
  } do
    state = base_state(cols: 80, rows: 24, sidebar_registry: table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true,
               focused?: true
             })

    state = %{state | layout: LayoutTUI.compute(state)}
    node = state |> FocusTree.from_state() |> FocusTree.hit_test(2, 2)

    assert node.content_type == {:custom, :sidebar}
    assert node.ref == "outline"
    assert node.handler == MingaEditor.Input.Sidebar
  end

  test "mouse input routes local coordinates through the generic sidebar handler", %{
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
               action_handler: fn state, "mouse", context ->
                 EditorState.set_status(
                   state,
                   "mouse #{context.row}:#{context.col}:#{context.button}:#{context.modifiers}:#{context.event_type}:#{context.click_count}"
                 )
               end
             })

    state = %{state | layout: LayoutTUI.compute(state)}
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

  test "TUI renderer uses cached snapshot rows", %{sidebar_registry: table} do
    state = base_state(cols: 80, rows: 24, sidebar_registry: table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true,
               snapshot: [
                 rows: [
                   %{id: "a", text: "alpha", icon: "λ", indent: 0},
                   %{id: "b", text: "beta", indent: 1, selected?: true}
                 ]
               ]
             })

    sidebar = SidebarRenderer.active_sidebar(state)
    draws = SidebarRenderer.render(state, {1, 0, 25, 10}, sidebar)
    texts = Enum.map(draws, fn {_row, _col, text, _face} -> String.trim(text) end)

    assert "Outline" in texts
    assert "λ alpha" in texts
    assert "beta" in Enum.map(texts, &String.trim/1)
  end

  test "non-built-in sidebar semantic kinds do not trigger built-in renderers", %{
    sidebar_registry: table
  } do
    state = base_state(cols: 80, rows: 24, sidebar_registry: table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true,
               semantic_kind: "file_tree",
               snapshot: [rows: [%{id: "a", text: "alpha"}]]
             })

    sidebar = SidebarRenderer.active_sidebar(state)
    draws = SidebarRenderer.render(state, {1, 0, 25, 10}, sidebar)
    texts = Enum.map(draws, fn {_row, _col, text, _face} -> String.trim(text) end)

    assert "Outline" in texts
    assert "alpha" in texts
  end

  defp flush_sidebar_messages(table) do
    receive do
      {:sidebar_changed, ^table} -> flush_sidebar_messages(table)
    after
      0 -> :ok
    end
  end
end
