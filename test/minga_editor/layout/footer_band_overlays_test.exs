defmodule MingaEditor.Layout.FooterBandOverlaysTest do
  @moduledoc """
  Promotion of active footer-band secondary overlays to registry-placed FocusTree
  nodes (#2281), plus the click-containment safety floor (AC-2).

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
  alias Minga.Mode.CommandState
  alias Minga.SystemObserver.ProcessSnapshot
  alias Minga.SystemObserver.TreeNode
  alias MingaEditor.Agent.DiffReview
  alias MingaAgent.ToolApproval.Preview, as: ApprovalPreview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias MingaEditor.Agent.Events, as: AgentEvents
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.FocusTree
  alias MingaEditor.Handlers.Notifications, as: NotificationHandlers
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Input.Router
  alias MingaEditor.Layout
  alias MingaEditor.Layout.OverlayBand
  alias MingaEditor.Layout.SurfaceRegistry
  alias MingaEditor.Observatory.Data, as: ObservatoryData
  alias MingaEditor.Agent.SemanticUI.Registry, as: SemanticUIRegistry
  alias MingaEditor.RenderModel.UI.AgentContextBuilder
  alias MingaEditor.RenderModel.UI.ExtensionOverlayBuilder
  alias MingaEditor.RenderModel.UI.ExtensionPanelBuilder
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Notification
  alias MingaEditor.Window

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

  defp register_surface(Minga.Extension.Panel, table, _buffer),
    do: Minga.Extension.Panel.set(table, :footer_test, "main", %{visible: true, title: "Panel"})

  defp register_surface(Minga.Extension.Overlay, table, buffer),
    do:
      Minga.Extension.Overlay.set(table, :footer_test, "mark", buffer,
        position: {0, 0},
        content: "mark"
      )

  defp register_surface(SemanticUIRegistry, table, _buffer) do
    SemanticUIRegistry.register(table, {:bundle, :footer_test}, %{
      id: "details",
      surface: :panel,
      payload: %Minga.RenderModel.UI.ExtensionPanel.Panel{
        extension: "semantic",
        panel_id: "details",
        title: "Details",
        position: :right,
        size: {:percent, 40},
        visible?: true,
        content: []
      }
    })
  end

  defp surface_entries(:extension_panel, ctx), do: ExtensionPanelBuilder.build(ctx).panels
  defp surface_entries(:extension_overlay, ctx), do: ExtensionOverlayBuilder.build(ctx).entries

  defp with_agent_context(state) do
    approval =
      Public.new(
        Target.new("footer-fixture", "admitted-request", "tc1"),
        "shell",
        %{},
        ApprovalPreview.new(:args, "", [])
      )

    frontend = %{state.frontend | backend: :gui}

    state
    |> Map.put(:frontend, frontend)
    |> AgentEvents.dispatch(self(), {:approval_pending, approval})
  end

  # The last row a footer band may cover: the editor area ends directly above the
  # terminal status row and minibuffer, which every band must leave visible.
  defp band_floor(state) do
    {row, _col, _width, height} = Layout.get(state).editor_area
    row + height
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

  describe "OverlayBand.rect/3" do
    test "clamps from the full terminal rows, as the Go TUI does, while anchoring in the editor area" do
      # 24-row terminal, editor area is 22 rows (status row + minibuffer below).
      # Go's maxOverlayHeight() gives 24/3 = 8, so a full band keeps 8 rows instead of 22/3 = 7.
      assert OverlayBand.rect({0, 0, 80, 22}, :max, 24) == {14, 0, 80, 8}
      # Content shorter than the clamp still hugs the bottom of the editor area.
      assert OverlayBand.rect({0, 0, 80, 22}, 3, 24) == {19, 0, 80, 3}
      # The band never grows past the area it is anchored in.
      assert OverlayBand.rect({0, 0, 80, 5}, :max, 24) == {0, 0, 80, 5}
    end
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

    test "a tiny grid keeps every overlay row within the viewport" do
      assert OverlayBand.rect({0, 0, 20, 0}, :max) == nil
      assert OverlayBand.rect({0, 0, 20, 1}, :max) == {0, 0, 20, 1}
      assert OverlayBand.rect({4, 0, 20, 3}, :max) == {4, 0, 20, 3}
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
      # height is title bar (1) + 2 lines per item = 3, plus the terminal frontend's
      # top and bottom border rows (2) = 5, under the band ceiling (24/3 = 8), so
      # the band is content-sized (5) and hugs the status row. This is the position
      # fix: a short notification no longer spans the full band and renders rows
      # above the bottom (#2281).
      assert col == 0
      assert width == 80
      assert height == 5
      assert row + height == band_floor(state)
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

      # title bar (1) + header+body (2) + actions row (1) + border frame (2) = 6
      assert height == 6
      assert row + height == band_floor(state)
    end

    test "the unpublished agent edits card keeps its Publish and Discard row inside the band" do
      # The terminal frontend crops the bordered notification center to this rect.
      # Before #3806 the rect omitted the two border rows, so the cropped frame
      # showed the title and dismiss "x" but lost the Publish and Discard row.
      state =
        base_state(rows: 40, cols: 120)
        |> NotificationHandlers.agent_edits_unpublished(1, "main", 1)

      assert [%{actions: actions}] = state.feedback.notifications.items
      assert Enum.map(actions, & &1.label) == ["Publish", "Discard"]

      {row, _col, _width, height} = SurfaceRegistry.rect_for(state, :notifications)

      # border (1) + title bar (1) + header + body (2) + actions (1) + border (1) = 6
      assert height == 6
      assert row + height == band_floor(state)
    end

    test "the observatory band height is one header plus one row per node" do
      # The Go renderer draws an addressable row per observatory node plus a header
      # row, and marks a click zone over each node row (#2334). The BEAM height must
      # equal 1 + node_count, or takeLines clips the trailing node rows out of the
      # band and their zones become unreachable (the #2333 height lesson). With 3
      # nodes the content height is 1 (header) + 3 = 4, under the band ceiling
      # (24/3 = 8), so the band is content-sized and hugs the status row.
      state = with_observatory_nodes(base_state(rows: 24, cols: 80), 3)

      {row, _col, _width, height} = SurfaceRegistry.rect_for(state, :observatory)

      assert height == 4
      assert row + height == band_floor(state)

      render_input = Input.from_editor_state(state)

      assert SurfaceRegistry.rect_for(render_input, :observatory) == {row, 0, 80, height}
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
      assert row + height == band_floor(state)
    end

    test "the agent context band leaves the terminal status row and command line visible" do
      normal = with_agent_context(base_state(rows: 24, cols: 80))

      command = %{
        normal
        | workspace:
            SessionState.transition_mode(normal.workspace, :command, CommandState.new(""))
      }

      for state <- [normal, command] do
        {minibuffer_row, _col, _width, _height} = Layout.get(state).minibuffer
        status_row = band_floor(state)
        {row, _col, _width, height} = SurfaceRegistry.rect_for(state, :agent_context)

        assert row + height == status_row
        refute SurfaceRegistry.within?(state, :agent_context, status_row, 0)
        refute SurfaceRegistry.within?(state, :agent_context, minibuffer_row, 0)
      end

      # The visible command line takes its own row below the status row.
      assert band_floor(command) == band_floor(normal) - 1
    end

    test "full Agent bodies retain activity data without a compact context overlay covering their controls" do
      for body <- [:chat, :review] do
        state = with_agent_context(base_state(rows: 24, cols: 80))
        id = state.workspace.windows.active
        window = Window.new_agent_chat(id, 24, 80)
        windows = Windows.replace_window(state.workspace.windows, id, window)

        ui =
          case body do
            :chat ->
              UIState.set_focus(state.workspace.agent_ui, :chat)

            :review ->
              state.workspace.agent_ui
              |> UIState.replace_preview(
                Preview.set_diff(Preview.new(), DiffReview.new("checkout.ex", "before", "after"))
              )
              |> UIState.set_focus(:file_viewer)
          end

        workspace =
          state.workspace
          |> SessionState.set_windows(windows)
          |> SessionState.set_agent_ui(ui)

        state = %{state | workspace: workspace}

        expected_content =
          if body == :chat, do: {:agent_chat, :semantic}, else: {:agent_review, :semantic}

        assert state.workspace.windows.map[id].content == expected_content
        assert AgentContextBuilder.build(Context.from_editor_state(state)).visible

        for input <- [state, Input.from_editor_state(state)] do
          assert SurfaceRegistry.rect_for(input, :agent_context) == nil
        end
      end
    end

    test "compact Agent context cannot cover the active subagent composer" do
      state = with_agent_context(base_state(rows: 24, cols: 80))
      windows = state.workspace.windows
      parent = windows.active
      {peek, windows} = Windows.allocate_id(windows)
      {:ok, tree} = MingaEditor.WindowTree.split(windows.tree, parent, :vertical, peek)
      chat = Window.new_agent_chat(parent, 24, 80)

      child =
        Window.new_subagent_peek(
          peek,
          {parent, {"task", {"request", "checkpoint", "call"}}},
          chat.viewport
        )

      windows =
        windows
        |> Windows.replace_window(parent, chat)
        |> Windows.set_tree(tree)
        |> Windows.add_window(child)
        |> Windows.set_active(peek)

      state = %{state | workspace: SessionState.set_windows(state.workspace, windows)}
      assert AgentContextBuilder.build(Context.from_editor_state(state)).visible

      for input <- [state, Input.from_editor_state(state)] do
        assert SurfaceRegistry.rect_for(input, :agent_context) == nil
      end
    end

    test "no footer overlay is placed when none is visible" do
      state = base_state()
      ids = state |> SurfaceRegistry.placements() |> Enum.map(& &1.surface_id)

      refute :notifications in ids
      refute :float_popup in ids
      refute :observatory in ids
    end

    test "tool manager registry identity is retired" do
      state = base_state()
      ids = state |> SurfaceRegistry.placements() |> Enum.map(& &1.surface_id)

      assert SurfaceRegistry.surface_id(:tool_manager) == nil
      refute :tool_manager in ids
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

  describe "extension surfaces come from the editor's own registries (#4274)" do
    # One row per registry the footer band reads.
    # A surface must reach the state that names its registry, in layout and in the render model, and no other state.
    registrations = [
      {:extension_panel, :extension_panel_registry, Minga.Extension.Panel},
      {:extension_panel, :agent_semantic_ui_registry, SemanticUIRegistry},
      {:extension_overlay, :extension_overlay_registry, Minga.Extension.Overlay}
    ]

    for {surface, option, registry} <- registrations do
      test "#{surface} from #{inspect(registry)} is placed only for the state that names it" do
        table = Module.concat(__MODULE__, "Owned#{System.unique_integer([:positive])}")
        start_supervised!({unquote(registry), name: table})

        owner = base_state([{unquote(option), table}])
        other = base_state()
        :ok = register_surface(unquote(registry), table, owner.workspace.buffers.active)

        for input <- [owner, Input.from_editor_state(owner)] do
          assert SurfaceRegistry.rect_for(input, unquote(surface)) != nil
        end

        for input <- [other, Input.from_editor_state(other)] do
          assert SurfaceRegistry.rect_for(input, unquote(surface)) == nil
        end

        assert surface_entries(unquote(surface), Context.from_editor_state(owner)) != []
        assert surface_entries(unquote(surface), Context.from_editor_state(other)) == []
      end
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
    test "the short notifications band hugs the status row, not the full band" do
      state = with_notifications(base_state(rows: 24, cols: 80))
      {row, _col, _w, height} = SurfaceRegistry.rect_for(state, :notifications)

      # One notification: band is content-sized (3 content rows + 2 border rows),
      # not the :max ceiling (8), and its bottom edge sits directly above the
      # status row and minibuffer, matching where the old footer-append put it.
      assert height == 5
      assert row + height == band_floor(state)
      assert row == band_floor(state) - 5
    end

    test "a click immediately above a short notification reaches the buffer" do
      # The notification band is the lowest 5 rows; the row directly above it is
      # outside the tightened rect, so a click there is NOT swallowed and
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
      {row, col, _w, _h} = OverlayBand.rect(layout.editor_area, :max)

      new_state = Router.dispatch_mouse(state, row, col, :left, 0, :press, 1)
      {cur_line, _cur_col} = BufferProcess.cursor(new_state.workspace.buffers.active)

      # The click row maps to a buffer line below the top, so the cursor moved off
      # line 0: the event reached the buffer because no sink swallowed it.
      assert cur_line > 0
    end
  end
end
