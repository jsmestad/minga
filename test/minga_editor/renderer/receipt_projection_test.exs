defmodule MingaEditor.Renderer.ReceiptProjectionTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.ReceiptProjection
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.WindowObservation
  alias MingaEditor.Renderer.ReviewObservation
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ClickRegions
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Render
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  test "projects one accepted receipt across workspace, shell, and render owners" do
    old_viewport = Viewport.new(40, 12)
    observed_viewport = Viewport.new(90, 30)
    window = Window.new(1, self(), old_viewport.rows, old_viewport.cols)

    workspace = %SessionState{
      buffers: %Buffers{active: self(), list: [self()]},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => window},
        active: 1,
        next_id: 2
      }
    }

    runtime = Runtime.new(Runtime.default_entry(), %TraditionalState{})
    regions = %ClickRegions{modeline: [{0, 3, :save}], tab_bar: [{0, 4, :tab_next}]}
    correlation = RenderCorrelation.frontend_ready(%RenderCorrelation{})

    receipt = %RenderReceipt{
      layout: nil,
      focus_tree: nil,
      shell_id: Runtime.id(runtime),
      shell_identity: Runtime.identity(runtime),
      click_regions: regions,
      frame_seq: 7,
      keyframe?: false,
      render_sent_at: 0,
      window_observations: %{
        1 => %WindowObservation{
          buffer: self(),
          buffer_version: 11,
          viewport: observed_viewport
        }
      }
    }

    {projected_workspace, projected_runtime, projected_render} =
      ReceiptProjection.project(workspace, runtime, %Render{}, receipt, correlation)

    assert projected_workspace.windows.map[1].viewport == observed_viewport
    assert projected_workspace.windows.map[1].render_cache.buffer_version == 11
    assert TraditionalState.click_regions(Runtime.state(projected_runtime)) == regions
    assert projected_render.render_correlation == correlation
    assert workspace.windows.map[1].viewport == old_viewport
    assert TraditionalState.click_regions(Runtime.state(runtime)) == %ClickRegions{}
  end

  test "matching review receipts update actual fit without reviving stale decisions or moving reading intent" do
    {workspace, runtime, observation} = review_context()
    selected = workspace.agent_ui.view.preview
    stale = Preview.refresh_after_write(selected, "selected.ex", "newer", EditTimeline.new())

    for preview <- [selected, stale] do
      workspace =
        SessionState.set_agent_ui(workspace, UIState.replace_preview(workspace.agent_ui, preview))

      projected = project_review(workspace, runtime, observation)
      observed = projected.agent_ui.view.preview

      assert projected.windows.map[1].viewport == observation.viewport
      assert observed.scroll.metrics == %{total_lines: 100, visible_height: 20}
      assert observed.scroll.offset == 12
      refute observed.scroll.pinned
      assert %{observed | scroll: preview.scroll} == preview
      assert projected.agent_ui.panel == workspace.agent_ui.panel
    end
  end

  test "review receipts cannot cross workspace, session, window incarnation or source revision" do
    {workspace, runtime, observation} = review_context()
    {group, session} = observation.scope
    moved_session = Runtime.set_tab_session(runtime, 1, self())

    for {runtime, observation} <- [
          {runtime, %{observation | scope: {group + 1, session}}},
          {moved_session, observation},
          {runtime,
           %{observation | accessibility_generation: observation.accessibility_generation + 1}}
        ] do
      assert project_review(workspace, runtime, observation) == workspace
    end

    preview = workspace.agent_ui.view.preview
    newer = Preview.set_diff(preview, Preview.diff_review(preview))

    changed =
      SessionState.set_agent_ui(workspace, UIState.replace_preview(workspace.agent_ui, newer))

    assert project_review(changed, runtime, observation) == changed

    window = Window.show_agent_body(workspace.windows.map[1], :chat)
    changed = SessionState.replace_window(workspace, 1, window)
    assert project_review(changed, runtime, observation) == changed
  end

  defp review_context do
    preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "after"))
    source = Preview.review_source(preview)
    {:ok, preview} = Preview.observe_review(preview, source, 100, 8)
    preview = Preview.scroll_down(preview, 12)
    window = Window.new_agent_chat(1, 8, 40) |> Window.show_agent_body(:review)

    {tab_bar, group} =
      Tab.new_agent(1, "Agent")
      |> TabBar.new(__DIR__)
      |> TabBar.add_workspace("Agent")

    tab_bar = TabBar.move_tab_to_workspace(tab_bar, 1, group.id)

    runtime =
      Runtime.new(
        Runtime.default_entry(),
        TraditionalState.install_tab_bar(%TraditionalState{}, tab_bar)
      )

    workspace = %SessionState{
      keymap_scope: :agent,
      agent_ui:
        UIState.new() |> UIState.replace_preview(preview) |> UIState.set_focus(:file_viewer),
      windows: %Windows{tree: WindowTree.new(1), map: %{1 => window}, active: 1, next_id: 2}
    }

    observation = %ReviewObservation{
      scope: Runtime.review_scope(runtime),
      accessibility_generation: window.accessibility_generation,
      source: source,
      viewport: Viewport.new(20, 60, 0),
      total_rows: 100
    }

    {workspace, runtime, observation}
  end

  defp project_review(workspace, runtime, observation) do
    receipt = %RenderReceipt{
      layout: nil,
      focus_tree: nil,
      shell_id: Runtime.id(runtime),
      shell_identity: Runtime.identity(runtime),
      click_regions: %ClickRegions{},
      frame_seq: 7,
      keyframe?: false,
      render_sent_at: 0,
      window_observations: %{1 => observation}
    }

    {workspace, _runtime, _render} =
      ReceiptProjection.project(workspace, runtime, %Render{}, receipt, %RenderCorrelation{})

    workspace
  end
end
