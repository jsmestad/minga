defmodule Minga.Editor.LayoutTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Agent.UIState
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.FileTree

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_state(rows, cols) do
    %EditorState{
      port_manager: nil,
      viewport: Viewport.new(rows, cols),
      vim: VimState.new()
    }
  end

  defp with_window(state, win_id \\ 1) do
    window = %Window{
      id: win_id,
      content: {:buffer, self()},
      buffer: self(),
      viewport: Viewport.new(24, 80)
    }

    %{
      state
      | windows: %Windows{
          tree: {:leaf, win_id},
          map: %{win_id => window},
          active: win_id,
          next_id: win_id + 1
        }
    }
  end

  defp with_file_tree(state, width) do
    tree = %FileTree{root: "/tmp", width: width}
    put_in(state.file_tree.tree, tree)
  end

  defp with_agent_panel(state) do
    default_panel = %AgentState{} |> Map.get(:panel)
    agent = %AgentState{panel: %{default_panel | visible: true}}
    agentic = UIState.new()
    agent_ctx = %{keymap_scope: :agent}

    # Ensure a file tab exists and is active, then add a background agent tab.
    # TabBar.new/1 requires an initial Tab; we start with a file tab.
    file_tab = %Minga.Editor.State.Tab{id: 1, kind: :file, label: "scratch"}
    tb = state.tab_bar || TabBar.new(file_tab)
    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent")
    tb = TabBar.update_context(tb, agent_tab.id, agent_ctx)

    # Keep the file tab active
    tb = TabBar.switch_to(tb, file_tab.id)

    %{state | tab_bar: tb, agent: agent, agent_ui: agentic}
  end

  defp with_vsplit(state) do
    win1 = %Window{
      id: 1,
      content: {:buffer, self()},
      buffer: self(),
      viewport: Viewport.new(24, 40)
    }

    win2 = %Window{
      id: 2,
      content: {:buffer, self()},
      buffer: self(),
      viewport: Viewport.new(24, 40)
    }

    %{
      state
      | windows: %Windows{
          tree: {:split, :vertical, {:leaf, 1}, {:leaf, 2}, 0},
          map: %{1 => win1, 2 => win2},
          active: 1,
          next_id: 3
        }
    }
  end

  defp with_hsplit(state) do
    win1 = %Window{
      id: 1,
      content: {:buffer, self()},
      buffer: self(),
      viewport: Viewport.new(12, 80)
    }

    win2 = %Window{
      id: 2,
      content: {:buffer, self()},
      buffer: self(),
      viewport: Viewport.new(12, 80)
    }

    %{
      state
      | windows: %Windows{
          tree: {:split, :horizontal, {:leaf, 1}, {:leaf, 2}, 0},
          map: %{1 => win1, 2 => win2},
          active: 1,
          next_id: 3
        }
    }
  end

  # ── Basic layout ─────────────────────────────────────────────────────────────
  # Tab bar at row 0, editor starts at row 1, minibuffer at last row.
  # For 24-row terminal: tab_bar={0,0,80,1}, editor={1,0,80,22}, minibuffer={23,0,80,1}

  describe "compute/1 single window" do
    test "full terminal minus minibuffer and tab bar rows" do
      state = new_state(24, 80) |> with_window()
      layout = Layout.compute(state)

      assert layout.terminal == {0, 0, 80, 24}
      assert layout.tab_bar == {0, 0, 80, 1}
      assert layout.minibuffer == {23, 0, 80, 1}
      assert layout.editor_area == {1, 0, 80, 22}
      assert layout.file_tree == nil
      assert layout.agent_panel == nil
    end

    test "single window gets content and modeline sub-rects" do
      state = new_state(24, 80) |> with_window()
      layout = Layout.compute(state)

      assert %{1 => wl} = layout.window_layouts
      assert wl.total == {1, 0, 80, 22}
      assert wl.content == {1, 0, 80, 21}
      assert wl.modeline == {22, 0, 80, 1}
    end
  end

  # ── File tree ──────────────────────────────────────────────────────────────

  describe "compute/1 with file tree" do
    test "file tree takes left columns, editor shifts right" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(30)
      layout = Layout.compute(state)

      # Tree starts at row 1 (below tab bar), height = 22 (24 - tab bar - minibuffer)
      assert layout.file_tree == {1, 0, 30, 22}
      assert layout.editor_area == {1, 31, 49, 22}
    end

    test "window layouts use editor area coordinates" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(30)
      layout = Layout.compute(state)

      %{1 => wl} = layout.window_layouts
      assert wl.total == {1, 31, 49, 22}
      assert wl.content == {1, 31, 49, 21}
      assert wl.modeline == {22, 31, 49, 1}
    end
  end

  # ── Agent panel ────────────────────────────────────────────────────────────

  describe "compute/1 with agent panel" do
    test "agent panel takes 35% of terminal rows" do
      state = new_state(24, 80) |> with_window() |> with_agent_panel()
      layout = Layout.compute(state)

      # remaining = 22 (24-2). 35% of 24 = 8 rows for agent panel.
      # editor_height = 22 - 8 = 14
      assert layout.agent_panel == {15, 0, 80, 8}
      assert layout.editor_area == {1, 0, 80, 14}
    end

    test "agent panel with file tree" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(20) |> with_agent_panel()
      layout = Layout.compute(state)

      # Agent panel is within the editor column space
      {_r, col, width, _h} = layout.agent_panel
      assert col == 21
      assert width == 59
    end
  end

  # ── Split windows ──────────────────────────────────────────────────────────

  describe "compute/1 with vertical split" do
    test "two windows side by side with modelines" do
      state = new_state(24, 80) |> with_vsplit()
      layout = Layout.compute(state)

      assert map_size(layout.window_layouts) == 2
      %{1 => left, 2 => right} = layout.window_layouts

      # Both windows should have modeline as last row
      {_, _, _, left_h} = left.total
      {lr, _, _, _} = left.modeline
      {ltr, _, _, _} = left.total
      assert lr == ltr + left_h - 1

      {_, _, _, right_h} = right.total
      {rr, _, _, _} = right.modeline
      {rtr, _, _, _} = right.total
      assert rr == rtr + right_h - 1
    end
  end

  describe "compute/1 with horizontal split" do
    test "two windows stacked with modelines" do
      state = new_state(24, 80) |> with_hsplit()
      layout = Layout.compute(state)

      assert map_size(layout.window_layouts) == 2
      %{1 => top, 2 => bottom} = layout.window_layouts

      # Top window modeline is at the boundary
      {tr, _, _, th} = top.total
      {tmr, _, _, _} = top.modeline
      assert tmr == tr + th - 1

      # Bottom window sits below the top
      {br, _, _, _} = bottom.total
      assert br == tr + th
    end
  end

  # ── Non-overlap invariant ──────────────────────────────────────────────────

  describe "non-overlap invariant" do
    test "no regions overlap in single window mode" do
      state = new_state(24, 80) |> with_window()
      layout = Layout.compute(state)
      assert_no_overlap(layout)
    end

    test "no regions overlap with file tree" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(30)
      layout = Layout.compute(state)
      assert_no_overlap(layout)
    end

    test "no regions overlap with agent panel" do
      state = new_state(24, 80) |> with_window() |> with_agent_panel()
      layout = Layout.compute(state)
      assert_no_overlap(layout)
    end

    test "no regions overlap with file tree and agent panel" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(20) |> with_agent_panel()
      layout = Layout.compute(state)
      assert_no_overlap(layout)
    end

    test "no regions overlap with vertical split" do
      state = new_state(24, 80) |> with_vsplit()
      layout = Layout.compute(state)
      assert_no_overlap(layout)
    end

    test "no regions overlap with horizontal split" do
      state = new_state(24, 80) |> with_hsplit()
      layout = Layout.compute(state)
      assert_no_overlap(layout)
    end
  end

  # ── Constraint satisfaction ──────────────────────────────────────────────────
  #
  # Constraints (from layout.ex):
  #   @editor_min_cols      10   — editor area never narrower than this
  #   @editor_min_rows       3   — editor area never shorter than this
  #   @file_tree_min_cols    8   — tree collapses below this width
  #   @agent_panel_min_rows  5   — panel collapses below this height
  #
  # Collapse priority: agent panel first, file tree second, editor never.

  describe "constraints: agent panel" do
    test "stays when panel height meets minimum" do
      # 17 rows. tab_bar=1, minibuffer=1, remaining=15. Panel = 35% of 17 = 5. Editor = 10.
      state = new_state(17, 80) |> with_window() |> with_agent_panel()
      layout = Layout.compute(state)
      assert layout.agent_panel != nil
      {_, _, _, ph} = layout.agent_panel
      assert ph == 5
    end

    test "collapses when panel height is below minimum (boundary)" do
      # 15 rows. tab_bar=1, minibuffer=1, remaining=13. Panel = 35% of 15 = 5.
      # Editor = 13-5 = 8. Both survive.
      # 14 rows. remaining=12. Panel = 35% of 14 = 4. 4 < 5 (min), collapse.
      state = new_state(14, 80) |> with_window() |> with_agent_panel()
      layout = Layout.compute(state)
      assert layout.agent_panel == nil
      {_, _, _, eh} = layout.editor_area
      assert eh == 12
    end

    test "collapses when remaining editor height would be below minimum" do
      # 9 rows. remaining=7. Panel = 35% of 9 = 3. 3 < 5, collapse.
      state = new_state(9, 80) |> with_window() |> with_agent_panel()
      layout = Layout.compute(state)
      assert layout.agent_panel == nil

      # 21 rows. remaining=19. Panel = 35% of 21 = 7. Editor = 19-7 = 12. Fine.
      state = new_state(21, 80) |> with_window() |> with_agent_panel()
      layout = Layout.compute(state)
      assert layout.agent_panel != nil
      {_, _, _, eh} = layout.editor_area
      assert eh == 12
    end
  end

  describe "constraints: file tree" do
    test "stays when editor width meets minimum (boundary)" do
      state = new_state(24, 21) |> with_window() |> with_file_tree(10)
      layout = Layout.compute(state)
      assert layout.file_tree != nil
      {_, _, tw, _} = layout.file_tree
      assert tw == 10
      {_, _, ew, _} = layout.editor_area
      assert ew == 10
    end

    test "collapses when editor width would be below minimum" do
      state = new_state(24, 20) |> with_window() |> with_file_tree(10)
      layout = Layout.compute(state)
      assert layout.file_tree == nil
      {_, col, ew, _} = layout.editor_area
      assert col == 0
      assert ew == 20
    end

    test "collapses when tree width is below its own minimum" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(5)
      layout = Layout.compute(state)
      assert layout.file_tree == nil
    end

    test "stays when tree width meets its own minimum (boundary)" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(8)
      layout = Layout.compute(state)
      assert layout.file_tree != nil
      {_, _, tw, _} = layout.file_tree
      assert tw == 8
    end

    test "wide tree gets clamped then collapses if clamped width < minimum" do
      state = new_state(24, 12) |> with_window() |> with_file_tree(30)
      layout = Layout.compute(state)
      assert layout.file_tree == nil
    end
  end

  describe "constraints: collapse order" do
    test "agent panel collapses before file tree when both are tight" do
      state = new_state(7, 50) |> with_window() |> with_file_tree(15) |> with_agent_panel()
      layout = Layout.compute(state)

      # Panel = 35% of 7 = 2 < 5, collapses
      assert layout.agent_panel == nil
      # Tree stays (50 - 15 - 1 = 34 >> 10)
      assert layout.file_tree != nil
    end

    test "both collapse when terminal is tiny" do
      state = new_state(5, 10) |> with_window() |> with_file_tree(8) |> with_agent_panel()
      layout = Layout.compute(state)
      assert layout.agent_panel == nil
      assert layout.file_tree == nil
      {_, col, w, h} = layout.editor_area
      assert col == 0
      assert w == 10
      assert h == 3
    end

    test "editor area always has positive dimensions at minimum terminal" do
      state = new_state(3, 3) |> with_window()
      layout = Layout.compute(state)
      {_, _, w, h} = layout.editor_area
      assert w > 0
      assert h > 0
    end

    test "file tree collapse recalculates agent panel rect with full width" do
      state = new_state(20, 40) |> with_window() |> with_file_tree(12) |> with_agent_panel()
      layout = Layout.compute(state)

      if layout.agent_panel != nil do
        {_, ac, aw, _} = layout.agent_panel
        {_, ec, ew, _} = layout.editor_area
        assert ac == ec
        assert aw == ew
      end
    end
  end

  describe "constraints: dynamic resize" do
    test "shrinking height collapses agent panel, file tree stays" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(20) |> with_agent_panel()
      layout = Layout.compute(state)
      assert layout.file_tree != nil
      assert layout.agent_panel != nil

      short_state = %{state | viewport: Viewport.new(7, 80)}
      layout = Layout.compute(short_state)
      assert layout.agent_panel == nil
      assert layout.file_tree != nil
    end

    test "shrinking width collapses file tree, agent panel unaffected" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(20) |> with_agent_panel()

      narrow_state = %{state | viewport: Viewport.new(24, 25)}
      layout = Layout.compute(narrow_state)
      assert layout.file_tree == nil
      assert layout.agent_panel != nil
    end

    test "growing terminal restores regions" do
      state = new_state(5, 10) |> with_window() |> with_file_tree(20) |> with_agent_panel()
      layout = Layout.compute(state)
      assert layout.agent_panel == nil
      assert layout.file_tree == nil

      big_state = %{state | viewport: Viewport.new(30, 100)}
      layout = Layout.compute(big_state)
      assert layout.agent_panel != nil
      assert layout.file_tree != nil
    end
  end

  # ── Resize ─────────────────────────────────────────────────────────────────

  describe "resize" do
    test "layout adapts to new terminal size" do
      state = new_state(24, 80) |> with_window()
      layout1 = Layout.compute(state)

      state2 = %{state | viewport: Viewport.new(40, 120)}
      layout2 = Layout.compute(state2)

      assert layout2.terminal == {0, 0, 120, 40}
      assert layout2.minibuffer == {39, 0, 120, 1}

      # Editor area grew
      {_, _, w1, h1} = layout1.editor_area
      {_, _, w2, h2} = layout2.editor_area
      assert w2 > w1
      assert h2 > h1
    end
  end

  # ── Property-based tests ──────────────────────────────────────────────────

  describe "property: no overlap for random configurations" do
    property "no regions overlap and no zero/negative dimensions for random terminal sizes" do
      check all(
              rows <- StreamData.integer(3..100),
              cols <- StreamData.integer(3..300),
              split_type <- StreamData.member_of([:none, :vertical, :horizontal]),
              has_tree <- StreamData.boolean(),
              has_agent <- StreamData.boolean()
            ) do
        state = new_state(rows, cols)

        state =
          case split_type do
            :none -> with_window(state)
            :vertical -> with_vsplit(state)
            :horizontal -> with_hsplit(state)
          end

        state = if has_tree, do: with_file_tree(state, 20), else: state
        state = if has_agent, do: with_agent_panel(state), else: state

        layout = Layout.compute(state)

        # All rects fit within terminal bounds
        {_tr, _tc, term_w, term_h} = layout.terminal
        all_rects = collect_all_rects(layout)

        for rect <- all_rects do
          {r, c, w, h} = rect
          assert r >= 0, "row #{r} < 0 in #{inspect(rect)}"
          assert c >= 0, "col #{c} < 0 in #{inspect(rect)}"
          assert w > 0, "width #{w} <= 0 in #{inspect(rect)}"
          assert h > 0, "height #{h} <= 0 in #{inspect(rect)}"
          assert r + h <= term_h, "rect #{inspect(rect)} exceeds terminal height #{term_h}"
          assert c + w <= term_w, "rect #{inspect(rect)} exceeds terminal width #{term_w}"
        end

        # Editor area always exists with positive dimensions
        {_, _, ew, eh} = layout.editor_area
        assert ew > 0, "editor width must be positive, got #{ew}"
        assert eh > 0, "editor height must be positive, got #{eh}"

        # Non-overlay rects don't overlap
        assert_no_overlap(layout)
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp collect_all_rects(layout) do
    base = [layout.tab_bar, layout.minibuffer]
    base = if layout.file_tree, do: [layout.file_tree | base], else: base
    base = if layout.agent_panel, do: [layout.agent_panel | base], else: base

    window_rects =
      layout.window_layouts
      |> Map.values()
      |> Enum.flat_map(fn wl -> [wl.content, wl.modeline] end)
      |> Enum.reject(fn {_r, _c, _w, h} -> h == 0 end)

    base ++ window_rects
  end

  defp assert_no_overlap(layout) do
    rects =
      [
        layout.tab_bar,
        layout.file_tree,
        layout.agent_panel,
        layout.minibuffer
      ]
      |> Enum.reject(&is_nil/1)

    window_rects =
      layout.window_layouts
      |> Map.values()
      |> Enum.flat_map(fn wl -> [wl.content, wl.modeline] end)
      |> Enum.reject(fn {_r, _c, _w, h} -> h == 0 end)

    all_rects = rects ++ window_rects

    for {r1, i} <- Enum.with_index(all_rects),
        {r2, j} <- Enum.with_index(all_rects),
        i < j do
      refute rects_overlap?(r1, r2),
             "Regions #{i} #{inspect(r1)} and #{j} #{inspect(r2)} overlap"
    end
  end

  defp rects_overlap?({r1, c1, w1, h1}, {r2, c2, w2, h2}) do
    not (c1 + w1 <= c2 or c2 + w2 <= c1 or r1 + h1 <= r2 or r2 + h2 <= r1)
  end

  describe "add_sidebar/1" do
    test "returns nil sidebar when window is too narrow" do
      layout = %{
        content: {0, 0, 80, 40},
        modeline: {40, 0, 80, 1},
        total: {0, 0, 80, 41},
        sidebar: nil
      }

      result = Layout.add_sidebar(layout)

      assert result.sidebar == nil
      assert result.content == {0, 0, 80, 40}
    end

    test "carves out sidebar when window exceeds threshold" do
      layout = %{
        content: {0, 0, 120, 40},
        modeline: {40, 0, 120, 1},
        total: {0, 0, 120, 41},
        sidebar: nil
      }

      result = Layout.add_sidebar(layout)

      {_, _, chat_w, _} = result.content
      {_, sidebar_col, sidebar_w, _} = result.sidebar

      # chat + 1 separator + sidebar = original width
      assert chat_w + 1 + sidebar_w == 120
      # sidebar starts after chat + separator
      assert sidebar_col == chat_w + 1
    end

    test "caps sidebar at one-third of window width" do
      layout = %{
        content: {0, 0, 90, 40},
        modeline: {40, 0, 90, 1},
        total: {0, 0, 90, 41},
        sidebar: nil
      }

      result = Layout.add_sidebar(layout)

      {_, _, sidebar_w, _} = result.sidebar
      assert sidebar_w == min(28, div(90, 3))
    end

    test "sidebar preserves row offset and height from content" do
      layout = %{
        content: {5, 10, 120, 30},
        modeline: {35, 10, 120, 1},
        total: {5, 10, 120, 31},
        sidebar: nil
      }

      result = Layout.add_sidebar(layout)

      {sr, _, _, sh} = result.sidebar
      {cr, _, _, ch} = result.content

      assert sr == cr
      assert sh == ch
    end
  end
end
