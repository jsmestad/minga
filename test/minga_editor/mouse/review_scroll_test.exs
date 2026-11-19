defmodule MingaEditor.Mouse.ReviewScrollTest do
  use ExUnit.Case, async: true

  alias Minga.Core.WidthOracle.Monospace
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.FocusTree.Node
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Mouse
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Renderer.WindowCache
  alias MingaEditor.RenderModel.Window.ReviewBuilder
  alias MingaEditor.RenderModel.Window.ReviewLayout
  alias MingaEditor.RenderPipeline.WindowIntent
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Theme
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  test "trackpad, routed wheel and scrollbar commit Review rows without replacing the retained source" do
    for route <- [:trackpad, :wheel, :scrollbar] do
      {state, first, cached} = reviewing_state()
      window = Map.fetch!(state.workspace.windows.map, 1)
      original_ui = state.workspace.agent_ui

      scrolled =
        case route do
          :trackpad ->
            Mouse.handle_scroll_batch(state, 1, 3, :down)

          :wheel ->
            Mouse.handle_at_node(
              state,
              %Node{id: :review, content_type: :buffer_content, ref: 1, rect: {0, 0, 16, 3}},
              1,
              1,
              :wheel_down,
              0,
              :press,
              1
            )

          :scrollbar ->
            GuiActionHandler.dispatch(
              state,
              {:scroll_to_line, 1, window.accessibility_generation, 3}
            )
        end

      assert scrolled.workspace.agent_ui.view.preview.scroll.offset > 0, inspect(route)
      assert scrolled.workspace.agent_ui.view.preview.content == original_ui.view.preview.content
      assert scrolled.workspace.agent_ui.panel == original_ui.panel

      assert MingaEditor.Agent.UIState.View.focus(scrolled.workspace.agent_ui.view) ==
               MingaEditor.Agent.UIState.View.focus(original_ui.view)

      assert scrolled.workspace.windows.active == state.workspace.windows.active
      assert scrolled.workspace.editing == state.workspace.editing
      updated_window = Map.fetch!(scrolled.workspace.windows.map, 1)
      assert updated_window.scroll_echo_anchor == {updated_window.viewport.top, 0, 0}

      intent = WindowIntent.from_window(updated_window)
      render_window = RenderWindow.materialize(1, intent, cached.render_cache)

      assert {:ok, next, _cache} =
               ReviewBuilder.build(
                 render_window,
                 scrolled.workspace.agent_ui.view.preview,
                 rects(),
                 layout(),
                 Runtime.review_scope(scrolled.shell_runtime)
               )

      assert next.geometry.viewport.top > first.geometry.viewport.top
      assert next.rows == first.rows
      assert next.row_delta == nil
      assert next.scroll_seq == first.scroll_seq
    end
  end

  defp reviewing_state do
    {tab_bar, group} =
      Tab.new_agent(1, "Agent") |> TabBar.new(__DIR__) |> TabBar.add_workspace("Agent")

    tab_bar = TabBar.move_tab_to_workspace(tab_bar, 1, group.id)
    window = Window.new_agent_chat(1, 3, 16)
    review = DiffReview.new("selected.ex", "before", String.duplicate("界é retained review ", 100))
    preview = Preview.new() |> Preview.set_diff(review) |> Preview.scroll_to_top()
    ui = UIState.new() |> UIState.replace_preview(preview) |> UIState.set_focus(:file_viewer)

    workspace = %SessionState{
      keymap_scope: :agent,
      windows: %Windows{tree: WindowTree.new(1), map: %{1 => window}, active: 1, next_id: 2}
    }

    state = %EditorState{
      workspace: SessionState.set_agent_ui(workspace, ui),
      shell_runtime:
        Runtime.new(Runtime.default_entry(), ShellState.install_tab_bar(%ShellState{}, tab_bar))
    }

    window = Map.fetch!(state.workspace.windows.map, 1)

    render_window =
      RenderWindow.materialize(1, WindowIntent.from_window(window), WindowCache.reset())

    {:ok, model, cached} =
      ReviewBuilder.build(
        render_window,
        preview,
        rects(),
        layout(),
        Runtime.review_scope(state.shell_runtime)
      )

    {:ok, preview} =
      Preview.observe_review(preview, Preview.review_source(preview), length(model.rows), 3)

    ui = UIState.replace_preview(ui, preview)
    {%{state | workspace: SessionState.set_agent_ui(state.workspace, ui)}, model, cached}
  end

  defp rects, do: %{content: {0, 0, 16, 3}, total: {0, 0, 16, 4}}
  defp layout, do: ReviewLayout.new(16, %Monospace{}, Theme.get!(:minga_default), 4)
end
