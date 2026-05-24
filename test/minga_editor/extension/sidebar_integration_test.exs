defmodule MingaEditor.Extension.SidebarIntegrationTest do
  # Uses the default named sidebar registry read by layout, focus-tree, and render paths.
  use ExUnit.Case, async: false

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FocusTree
  alias MingaEditor.Input.Router
  alias MingaEditor.Shell.Traditional.Layout.TUI, as: LayoutTUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Shell.Traditional.SidebarRenderer

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    Sidebar.unregister_source({:extension, :outline})

    on_exit(fn ->
      Sidebar.unregister_source({:extension, :outline})
    end)

    :ok
  end

  test "layout reserves and reclaims space for a visible registered sidebar" do
    state = base_state(cols: 80, rows: 24)

    assert LayoutTUI.compute(state).file_tree == nil

    assert :ok =
             Sidebar.register({:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true
             })

    layout = LayoutTUI.compute(state)
    assert {1, 0, 25, 21} = layout.file_tree
    assert {1, 26, 54, 21} = layout.editor_area

    assert :ok = Sidebar.set_visible({:extension, :outline}, "outline", false)
    assert LayoutTUI.compute(state).file_tree == nil
  end

  test "tiny terminals collapse registered sidebars instead of invalid editor dimensions" do
    state = base_state(cols: 12, rows: 8)

    assert :ok =
             Sidebar.register({:extension, :outline}, %{
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

  test "focus tree routes registered sidebars to the generic sidebar handler" do
    state = base_state(cols: 80, rows: 24)

    assert :ok =
             Sidebar.register({:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               preferred_width: 25,
               visible?: true,
               focused?: true
             })

    node = state |> LayoutTUI.compute() |> FocusTree.from_layout() |> FocusTree.hit_test(2, 2)

    assert node.content_type == {:custom, :sidebar}
    assert node.ref == "outline"
    assert node.handler == MingaEditor.Input.Sidebar
  end

  test "keyboard input routes through the generic sidebar handler when focused" do
    state = base_state(cols: 80, rows: 24)

    assert :ok =
             Sidebar.register({:extension, :outline}, %{
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

  test "snapshot updates notify the editor render loop" do
    Process.register(self(), MingaEditor)

    assert :ok =
             Sidebar.register({:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               visible?: true
             })

    flush_render_messages()

    assert :ok =
             Sidebar.publish_snapshot({:extension, :outline}, "outline",
               rows: [%{id: "a", text: "alpha"}]
             )

    assert_receive {:"$gen_cast", :render}
  after
    if Process.whereis(MingaEditor) == self(), do: Process.unregister(MingaEditor)
  end

  test "TUI renderer uses cached snapshot rows" do
    state = base_state(cols: 80, rows: 24)

    assert :ok =
             Sidebar.register({:extension, :outline}, %{
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

    draws = SidebarRenderer.render(state, {1, 0, 25, 10})
    texts = Enum.map(draws, fn {_row, _col, text, _face} -> String.trim(text) end)

    assert "Outline" in texts
    assert "λ alpha" in texts
    assert "beta" in Enum.map(texts, &String.trim/1)
  end

  defp flush_render_messages do
    receive do
      {:"$gen_cast", :render} -> flush_render_messages()
    after
      0 -> :ok
    end
  end
end
