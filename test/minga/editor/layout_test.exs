defmodule Minga.Editor.LayoutTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.FileTree
  alias Minga.Mode

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_state(rows, cols) do
    %EditorState{
      port_manager: nil,
      viewport: Viewport.new(rows, cols),
      mode: :normal,
      mode_state: Mode.initial_state()
    }
  end

  defp with_window(state, win_id \\ 1) do
    window = %Window{id: win_id, buffer: self(), viewport: Viewport.new(24, 80)}

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
    put_in(state.agent.panel.visible, true)
  end

  defp with_vsplit(state) do
    win1 = %Window{id: 1, buffer: self(), viewport: Viewport.new(24, 40)}
    win2 = %Window{id: 2, buffer: self(), viewport: Viewport.new(24, 40)}

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
    win1 = %Window{id: 1, buffer: self(), viewport: Viewport.new(12, 80)}
    win2 = %Window{id: 2, buffer: self(), viewport: Viewport.new(12, 80)}

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

  describe "compute/1 single window" do
    test "full terminal minus minibuffer row" do
      state = new_state(24, 80) |> with_window()
      layout = Layout.compute(state)

      assert layout.terminal == {0, 0, 80, 24}
      assert layout.minibuffer == {23, 0, 80, 1}
      assert layout.editor_area == {0, 0, 80, 23}
      assert layout.file_tree == nil
      assert layout.agent_panel == nil
    end

    test "single window gets content and modeline sub-rects" do
      state = new_state(24, 80) |> with_window()
      layout = Layout.compute(state)

      assert %{1 => wl} = layout.window_layouts
      assert wl.total == {0, 0, 80, 23}
      assert wl.content == {0, 0, 80, 22}
      assert wl.modeline == {22, 0, 80, 1}
    end
  end

  # ── File tree ──────────────────────────────────────────────────────────────

  describe "compute/1 with file tree" do
    test "file tree takes left columns, editor shifts right" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(30)
      layout = Layout.compute(state)

      # Tree: columns 0..29, separator at 30, editor starts at 31
      assert layout.file_tree == {0, 0, 30, 23}
      assert layout.editor_area == {0, 31, 49, 23}
    end

    test "window layouts use editor area coordinates" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(30)
      layout = Layout.compute(state)

      %{1 => wl} = layout.window_layouts
      assert wl.total == {0, 31, 49, 23}
      assert wl.content == {0, 31, 49, 22}
      assert wl.modeline == {22, 31, 49, 1}
    end
  end

  # ── Agent panel ────────────────────────────────────────────────────────────

  describe "compute/1 with agent panel" do
    test "agent panel takes 35% of terminal rows" do
      state = new_state(24, 80) |> with_window() |> with_agent_panel()
      layout = Layout.compute(state)

      # 35% of 24 = 8 rows for agent panel
      # editor_height = 23 (total - minibuffer) - 8 = 15
      assert layout.agent_panel == {15, 0, 80, 8}
      assert layout.editor_area == {0, 0, 80, 15}
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

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # ── Property-based tests ──────────────────────────────────────────────────

  describe "property: no overlap for random configurations" do
    property "no regions overlap for random terminal sizes and split trees" do
      check all(
              rows <- StreamData.integer(5..100),
              cols <- StreamData.integer(20..300),
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
          assert r + h <= term_h, "rect #{inspect(rect)} exceeds terminal height #{term_h}"
          assert c + w <= term_w, "rect #{inspect(rect)} exceeds terminal width #{term_w}"
        end

        # Non-overlay rects don't overlap
        assert_no_overlap(layout)
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp collect_all_rects(layout) do
    base = [layout.minibuffer]
    base = if layout.file_tree, do: [layout.file_tree | base], else: base
    base = if layout.agent_panel, do: [layout.agent_panel | base], else: base

    window_rects =
      layout.window_layouts
      |> Map.values()
      |> Enum.flat_map(fn wl -> [wl.content, wl.modeline] end)
      |> Enum.reject(fn {_r, _c, _w, h} -> h == 0 end)

    base ++ window_rects
  end

  # Asserts that no two non-overlay regions share any cells.
  defp assert_no_overlap(layout) do
    rects =
      [
        layout.file_tree,
        layout.agent_panel,
        layout.minibuffer
      ]
      |> Enum.reject(&is_nil/1)

    # Add window content and modeline rects (not total, to avoid double-counting).
    # Skip zero-height rects (collapsed modelines in tiny windows).
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
    # Two rects overlap if they share at least one cell.
    # They don't overlap if one is entirely left/right/above/below the other.
    not (c1 + w1 <= c2 or c2 + w2 <= c1 or r1 + h1 <= r2 or r2 + h2 <= r1)
  end
end
