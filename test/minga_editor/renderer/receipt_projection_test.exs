defmodule MingaEditor.Renderer.ReceiptProjectionTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.ReceiptProjection
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.WindowObservation
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ClickRegions
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Render
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  test "projects one accepted receipt across workspace, shell, and render owners" do
    old_viewport = Viewport.new(40, 12)
    observed_viewport = Viewport.new(90, 30)
    window = Window.new(1, self(), old_viewport.rows, old_viewport.cols)

    workspace = %SessionState{
      viewport: old_viewport,
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
end
