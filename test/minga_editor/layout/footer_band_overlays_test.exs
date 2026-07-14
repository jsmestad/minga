defmodule MingaEditor.Layout.FooterBandOverlaysTest do
  @moduledoc """
  Promotion of the eight footer-band secondary overlays to registry-placed
  FocusTree nodes (#2281), plus the click-containment safety floor (AC-2).

  Covers four things:

    * `OverlayBand.rect/2` ports the Go `maxOverlayHeight` clamp and bottom-anchors.
    * A visible footer surface (notifications) becomes a FocusTree overlay node
      and a `SurfaceRegistry` placement with the historical stacking z.
    * A click or scroll over a visible overlay is swallowed by `Input.OverlaySink`
      and never reaches the buffer underneath.
    * With the overlay hidden, the same click reaches the buffer and moves its cursor.
  """

  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.SystemObserver.ProcessSnapshot
  alias Minga.SystemObserver.TreeNode
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.Events, as: AgentEvents
  alias MingaEditor.FocusTree
  alias MingaEditor.Input.Router
  alias MingaEditor.Layout
  alias MingaEditor.Layout.OverlayBand
  alias MingaEditor.Layout.SurfaceRegistry
  alias MingaEditor.Observatory.Data, as: ObservatoryData
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Feedback
  alias MingaEditor.UI.Notification

  defp with_notifications(state) do
    note =
      Notification.new(%{
        id: "n1",
        level: :info,
        title: "Build finished",
        created_at: System.system_time(:millisecond)
      })

    %{state | feedback: Feedback.upsert_notification(state.feedback, note)}
  end

  defp with_observatory(state), do: SidebarWorkflow.open_observatory(state, nil)

  defp with_agent_context(state) do
    approval = %{tool_call_id: "tc1", name: "shell", args: %{}}

    state = MingaEditor.Shell.Traditional.Workflow.install_agent_approval(state, approval)

    {state, _effects} = AgentEvents.handle(state, {:approval_pending, approval})
    state
  end

  # Builds an observatory tree with `count` nodes (one root plus count-1 direct
  # children) so content_height_observatory counts a real flattened node list,
  # not the empty-state fallback. Snapshots carry only the metrics the count needs.
  defp with_observatory_nodes(state, count) when count >= 1 do
    snapshot = %ProcessSnapshot{memory: 0, message_queue_len: 0, reductions: 0}

    children =
      for _ <- 2..count//1 do
        %TreeNode{pid: spawn(fn -> :ok end), snapshot: snapshot, children: [], depth: 1}
      end

    tree = %TreeNode{pid: spawn(fn -> :ok end), snapshot: snapshot, children: children, depth: 0}

    state
    |> with_observatory()
    |> SidebarWorkflow.replace_observatory_data(ObservatoryData.visible(tree, []))
  end

  # Records `count` agent edits for the active buffer's path and wires the
  # resulting timeline into the agent UI view, so edit_timeline becomes visible
  # and content_height_edit_timeline counts a real entry list. The buffer is
  # saved to a temp path so active_buffer_path/1 has a non-nil path to key on.
  defp with_edit_timeline(state, count) when count >= 1 do
    buf = state.workspace.buffers.active
    path = Path.join(System.tmp_dir!(), "edit-timeline-#{System.unique_integer([:positive])}.ex")
    :ok = BufferProcess.save_as(buf, path)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    resolved = BufferProcess.file_path(buf)

    timeline =
      Enum.reduce(1..count, EditTimeline.new(), fn i, acc ->
        EditTimeline.record_edit(acc, resolved, "call-#{i}", "write_file", "before", "after #{i}")
      end)

    agent_ui = %{
      state.workspace.agent_ui
      | view: %{state.workspace.agent_ui.view | edit_timeline: timeline}
    }

    %{state | workspace: SessionState.set_agent_ui(state.workspace, agent_ui)}
  end

  describe "OverlayBand.rect/2" do
    test "clamps band height to the Go maxOverlayHeight floor/ceiling and bottom-anchors" do
      # 24 rows: 24/3 = 8, within [4, 12]. Content asks for max (clamp ceiling).
      terminal = {0, 0, 80, 24}
      assert OverlayBand.rect(terminal, :max) == {16, 0, 80, 8}

      # Tall terminal: clamp ceiling 12 caps the band.
      assert OverlayBand.rect({0, 0, 80, 60}, :max) == {48, 0, 80, 12}

      # Short terminal: clamp floor 4 keeps a minimum band.
      assert OverlayBand.rect({0, 0, 80, 9}, :max) == {5, 0, 80, 4}
    end

    test "a content height smaller than the clamp shrinks the band to fit content" do
      # 3 content lines < clamp (8 for 24 rows): band is 3 tall.
      assert OverlayBand.rect({0, 0, 80, 24}, 3) == {21, 0, 80, 3}
    end
  end

  describe "FooterOverlays visibility and registry placement" do
    test "a visible notifications surface is a registry placement at z=160" do
      state = with_notifications(base_state())
      placements = SurfaceRegistry.placements(state)
      ids = Enum.map(placements, & &1.surface_id)

      assert :notifications in ids
      rect = SurfaceRegistry.rect_for(state, :notifications)
      assert rect != nil

      placement = Enum.find(placements, &(&1.surface_id == :notifications))
      assert placement.z == 160
      assert placement.hit_kind == :overlay
    end

    test "the notifications placement is the full-width bottom band sized to its content" do
      state = with_notifications(base_state(rows: 24, cols: 80))
      {row, col, width, height} = SurfaceRegistry.rect_for(state, :notifications)

      # Full width, bottom-anchored. With ONE notification item the BEAM content
      # height is title bar (1) + 2 lines per item = 3, well under the band ceiling
      # (24/3 = 8), so the band is content-sized (3) and hugs the screen bottom.
      # This is the position fix: a short notification no longer spans the full band
      # and renders rows above the bottom (#2281).
      assert col == 0
      assert width == 80
      assert height == 3
      assert row + height == 24
    end

    test "an item with inline actions adds one row to the notifications band" do
      # The Go renderer draws an actions row for items carrying inline actions
      # (#2333). The BEAM height must count it: an undercounted rect clips the
      # actions row out of the band and its click zones become unreachable.
      note =
        Notification.new(%{
          id: "n-actions",
          level: :error,
          title: "Build failed",
          created_at: System.system_time(:millisecond),
          actions: [%{id: "retry", label: "Retry", dispatch: {:command, :test_rerun}}]
        })

      state = base_state(rows: 24, cols: 80)
      state = %{state | feedback: Feedback.upsert_notification(state.feedback, note)}

      {row, _col, _width, height} = SurfaceRegistry.rect_for(state, :notifications)

      # title bar (1) + header+body (2) + actions row (1) = 4
      assert height == 4
      assert row + height == 24
    end

    test "the observatory band height is one header plus one row per node" do
      # The Go renderer draws an addressable row per observatory node plus a header
      # row, and marks a click zone over each node row (#2334). The BEAM height must
      # equal 1 + node_count, or takeLines clips the trailing node rows out of the
      # band and their zones become unreachable (the #2333 height lesson). With 3
      # nodes the content height is 1 (header) + 3 = 4, under the band ceiling
      # (24/3 = 8), so the band is content-sized and hugs the screen bottom.
      state = with_observatory_nodes(base_state(rows: 24, cols: 80), 3)

      {row, _col, _width, height} = SurfaceRegistry.rect_for(state, :observatory)

      assert height == 4
      assert row + height == 24

      render_input = Input.from_editor_state(state)

      assert SurfaceRegistry.rect_for(render_input, :observatory) == {row, 0, 80, height}
    end

    test "the edit timeline band height is one header plus one row per entry" do
      # The Go renderer draws an addressable row per timeline entry plus a header
      # row, and marks a click zone over each entry row (#2335). The BEAM height must
      # equal 1 + entry_count for the same clip-the-zones reason as observatory and
      # notifications. With 2 entries the content height is 1 (header) + 2 = 3.
      state = with_edit_timeline(base_state(rows: 24, cols: 80), 2)

      {row, _col, _width, height} = SurfaceRegistry.rect_for(state, :edit_timeline)

      assert height == 3
      assert row + height == 24
    end

    test "pending approval alone places the agent context band" do
      state = with_agent_context(base_state(rows: 24, cols: 80))

      assert MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state).pending_approval !=
               nil

      assert state.workspace.agent_ui.view.activity.todos == []
      assert state.workspace.agent_ui.view.activity.tool_count == 0

      {row, _col, _width, height} = SurfaceRegistry.rect_for(state, :agent_context)
      ids = state |> SurfaceRegistry.placements() |> Enum.map(& &1.surface_id)

      assert :agent_context in ids
      assert height > 0
      assert row + height == 24
    end

    test "no footer overlay is placed when none is visible" do
      state = base_state()
      ids = state |> SurfaceRegistry.placements() |> Enum.map(& &1.surface_id)

      refute :notifications in ids
      refute :float_popup in ids
      refute :observatory in ids
    end

    test "the notifications focus node routes to the swallow-by-default sink" do
      state = with_notifications(base_state())
      tree = FocusTree.from_state(state)
      {r, c, _w, _h} = SurfaceRegistry.rect_for(state, :notifications)

      node = FocusTree.hit_test(tree, r, c)
      assert node.content_type == :notifications
      assert node.handler == MingaEditor.Input.OverlaySink
    end
  end

  describe "hit-test winner matches the render winner (#2281)" do
    test "two visible overlays resolve to the higher-z surface over the shared band" do
      # Notifications (z=160) and observatory (z=180) are both visible this frame.
      # Go composites the HIGHEST-z surface on top (observatory, 180), so the BEAM
      # hit-test over the shared bottom band MUST resolve to observatory too: the
      # hit-winner must equal the render-winner, or #2330's per-surface handlers
      # would route a click to the wrong surface.
      state =
        base_state(rows: 24, cols: 80)
        |> with_notifications()
        |> with_observatory()

      placements = SurfaceRegistry.placements(state)
      ids = Enum.map(placements, & &1.surface_id)
      assert :notifications in ids
      assert :observatory in ids

      tree = FocusTree.from_state(state)

      # A point inside both bands (both are full-width, bottom-anchored). Use the
      # observatory band's bottom-left cell, which both rects contain.
      {obs_row, obs_col, _w, obs_h} = SurfaceRegistry.rect_for(state, :observatory)
      hit_row = obs_row + obs_h - 1

      node = FocusTree.hit_test(tree, hit_row, obs_col)

      assert node.content_type == :observatory,
             "expected the higher-z observatory to win the hit-test, got #{inspect(node.content_type)}"
    end

    test "across the full shared overlap the higher-z surface always wins" do
      # Wherever the two bands overlap (both are full-width, bottom-anchored, so the
      # shorter band's rows are a subset of the taller band's), the hit-test must
      # return the higher-z observatory, never the lower-z notifications. This is
      # the exact inversion the bug produced: appending visible/1 in descending z
      # made the lowest-z node the last child, so the reversed hit-test picked it.
      state =
        base_state(rows: 24, cols: 80)
        |> with_notifications()
        |> with_observatory()

      tree = FocusTree.from_state(state)
      {n_row, n_col, _nw, n_h} = SurfaceRegistry.rect_for(state, :notifications)
      {o_row, _oc, _ow, o_h} = SurfaceRegistry.rect_for(state, :observatory)

      overlap_top = max(n_row, o_row)
      overlap_bottom = min(n_row + n_h, o_row + o_h) - 1

      for row <- overlap_top..overlap_bottom do
        node = FocusTree.hit_test(tree, row, n_col)

        assert node.content_type == :observatory,
               "row #{row} in the shared band resolved to #{inspect(node.content_type)}, expected the higher-z observatory"
      end
    end
  end

  describe "short-overlay position pinning (#2281)" do
    test "the short notifications band hugs the screen bottom, not the full band" do
      state = with_notifications(base_state(rows: 24, cols: 80))
      {row, _col, _w, height} = SurfaceRegistry.rect_for(state, :notifications)

      # One notification: band is content-sized (3), not the :max ceiling (8), and
      # its bottom edge is the screen bottom (above the minibuffer), matching where
      # the old footer-append put it.
      assert height == 3
      assert row + height == 24
      assert row == 21
    end

    test "a click immediately above a short notification reaches the buffer" do
      # The notification band is the lowest 3 rows; the row directly above it (row
      # 20) is outside the tightened rect, so a click there is NOT swallowed and
      # reaches the buffer underneath. Before the fix the rect spanned the full band
      # and this row phantom-swallowed the click.
      state =
        [rows: 24, cols: 80, content: long_content(200)]
        |> base_state()
        |> seed_state(0)
        |> with_notifications()

      assert {0, 0} == BufferProcess.cursor(state.workspace.buffers.active)

      {n_row, n_col, _w, _h} = SurfaceRegistry.rect_for(state, :notifications)
      above_row = n_row - 1

      # The row above the band is buffer content, not overlay: confirm no overlay
      # rect contains it.
      refute SurfaceRegistry.within?(state, :notifications, above_row, n_col)

      new_state = Router.dispatch_mouse(state, above_row, n_col, :left, 0, :press, 1)
      {cur_line, _cur_col} = BufferProcess.cursor(new_state.workspace.buffers.active)

      assert cur_line > 0,
             "a click above the tightened notifications band should reach the buffer"
    end
  end

  describe "click containment (AC-2)" do
    test "a click over a visible notifications overlay does not move the buffer cursor" do
      state = with_notifications(base_state())
      buf = state.workspace.buffers.active
      before = BufferProcess.cursor(buf)

      {r, c, _w, _h} = SurfaceRegistry.rect_for(state, :notifications)
      # The overlay sits at the bottom band, over buffer text; a raw click there
      # would normally move the cursor. The sink must swallow it.
      _state = Router.dispatch_mouse(state, r, c, :left, 0, :press, 1)

      assert BufferProcess.cursor(buf) == before
    end

    test "a scroll over a visible notifications overlay does not scroll the buffer" do
      # Tall buffer so a wheel event on the buffer would scroll it.
      state =
        [rows: 24, cols: 80, content: long_content(200)]
        |> base_state()
        |> seed_state(0)
        |> with_notifications()

      win_id = state.workspace.windows.active
      before_top = state.workspace.windows.map[win_id].viewport.top

      {r, c, _w, _h} = SurfaceRegistry.rect_for(state, :notifications)
      new_state = Router.dispatch_mouse(state, r, c, :wheel_down, 0, :press, 1)

      after_top = new_state.workspace.windows.map[win_id].viewport.top
      assert after_top == before_top
    end

    test "with notifications hidden, the same click reaches the buffer and moves its cursor" do
      # Same geometry, but no overlay: the click lands on buffer text and the
      # normal-mode mouse handler moves the cursor there. This proves the sink is
      # gated on visibility, not unconditionally swallowing buffer clicks. A tall
      # buffer guarantees the click row maps to a real, non-zero buffer line.
      state =
        [rows: 24, cols: 80, content: long_content(200)]
        |> base_state()
        |> seed_state(0)

      assert {0, 0} == BufferProcess.cursor(state.workspace.buffers.active)

      # The band's top row, in the content area, is where the overlay would have
      # sat: the only difference from the visible case is the overlay's presence.
      layout = Layout.get(state)
      {row, col, _w, _h} = OverlayBand.rect(layout.terminal, :max)

      new_state = Router.dispatch_mouse(state, row, col, :left, 0, :press, 1)
      {cur_line, _cur_col} = BufferProcess.cursor(new_state.workspace.buffers.active)

      # The click row maps to a buffer line below the top, so the cursor moved off
      # line 0: the event reached the buffer because no sink swallowed it.
      assert cur_line > 0
    end
  end
end
