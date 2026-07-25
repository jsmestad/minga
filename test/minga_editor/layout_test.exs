defmodule MingaEditor.LayoutTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias Minga.Project.FileTree

  # Every live frontend is semantic (`Layout.GUI`); the legacy cell-grid
  # `Layout.TUI` and its reserved tab-bar/file-tree/agent-panel geometry were
  # deleted in #2235. These tests drive the surviving GUI layout under native-GUI
  # capabilities: the Metal viewport is pure editor area that fills the whole
  # reported grid (the minibuffer is native chrome rendered outside the surface,
  # so no grid row is reserved, #2693), plus the shared window-subdivision/split
  # math in `MingaEditor.Layout`.

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    Process.put(:sidebar_registry, table)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_state(rows, cols) do
    vp = Viewport.new(rows, cols)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{
        port_manager: nil,
        terminal_viewport: vp,
        capabilities: %MingaEditor.Frontend.Capabilities{
          frontend_type: :native_gui,
          semantic_ui: true
        }
      },
      extension_surfaces: %MingaEditor.State.ExtensionSurfaces{
        sidebar_registry: Process.get(:sidebar_registry)
      },
      workspace: %MingaEditor.Session.State{
        editing: VimState.new()
      }
    }
  end

  defp with_window(state, win_id \\ 1) do
    window = %Window{
      id: win_id,
      content: {:buffer, self()},
      viewport: Viewport.new(24, 80)
    }

    %{
      state
      | workspace:
          SessionState.set_windows(state.workspace, %Windows{
            tree: {:leaf, win_id},
            map: %{win_id => window},
            active: win_id,
            next_id: win_id + 1
          })
    }
  end

  defp with_file_tree(state, width) do
    file_tree =
      MingaEditor.State.FileTree.open(
        %MingaEditor.State.FileTree{},
        %FileTree{root: "/tmp", width: width},
        nil
      )

    then(state, fn state ->
      %{
        state
        | workspace:
            then(state.workspace, fn workspace ->
              MingaEditor.Session.State.set_file_tree(workspace, file_tree)
            end)
      }
    end)
  end

  defp with_agent_panel(state) do
    agent = %AgentState{}
    base = UIState.new()
    agentic = %{base | panel: %{base.panel | visible: true}}
    agent_ctx = %{keymap_scope: :agent}

    file_tab = MingaEditor.State.Tab.new_file(1, "scratch")
    tb = state.shell_runtime.state.tab_bar || TabBar.new(file_tab)
    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent")
    tb = TabBar.update_context(tb, agent_tab.id, agent_ctx)
    tb = TabBar.switch_to(tb, file_tab.id)

    state
    |> then(fn state ->
      %{
        state
        | workspace:
            then(state.workspace, fn workspace ->
              MingaEditor.Session.State.set_agent_ui(workspace, agentic)
            end)
      }
    end)
    |> then(fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.install_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          tb
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
    |> MingaEditor.Shell.Traditional.Workflow.install_agent_state(agent)
  end

  defp with_vsplit(state) do
    win1 = %Window{
      id: 1,
      content: {:buffer, self()},
      viewport: Viewport.new(24, 40)
    }

    win2 = %Window{
      id: 2,
      content: {:buffer, self()},
      viewport: Viewport.new(24, 40)
    }

    %{
      state
      | workspace:
          SessionState.set_windows(state.workspace, %Windows{
            tree: {:split, :vertical, {:leaf, 1}, {:leaf, 2}, 0},
            map: %{1 => win1, 2 => win2},
            active: 1,
            next_id: 3
          })
    }
  end

  defp with_hsplit(state) do
    win1 = %Window{
      id: 1,
      content: {:buffer, self()},
      viewport: Viewport.new(12, 80)
    }

    win2 = %Window{
      id: 2,
      content: {:buffer, self()},
      viewport: Viewport.new(12, 80)
    }

    %{
      state
      | workspace:
          SessionState.set_windows(state.workspace, %Windows{
            tree: {:split, :horizontal, {:leaf, 1}, {:leaf, 2}, 0},
            map: %{1 => win1, 2 => win2},
            active: 1,
            next_id: 3
          })
    }
  end

  # ── Single window ────────────────────────────────────────────────────────────

  describe "compute/1 single window" do
    test "native GUI editor area fills the full viewport (minibuffer is native chrome)" do
      state = new_state(24, 80) |> with_window()
      layout = Layout.compute(state)

      assert layout.terminal == {0, 0, 80, 24}
      # SwiftUI/Go render tab bar, status bar, file tree, and minibuffer natively;
      # the reported rows already exclude them, so the BEAM reserves no rows or
      # columns. The editor claims the whole viewport (#2693) and the minibuffer
      # rect is anchored just below the content grid for cursor/focus routing.
      assert layout.tab_bar == nil
      assert layout.status_bar == nil
      assert layout.file_tree == nil
      assert layout.agent_panel == nil
      assert layout.minibuffer == {24, 0, 80, 1}
      assert layout.editor_area == {0, 0, 80, 24}
    end

    test "single window fills the editor area without a per-window modeline" do
      state = new_state(24, 80) |> with_window()
      layout = Layout.compute(state)

      assert %{1 => wl} = layout.window_layouts
      assert wl.total == {0, 0, 80, 24}
      assert wl.content == wl.total
      refute Map.has_key?(wl, :modeline)
    end

    test "file tree open does not reserve BEAM columns" do
      state = new_state(24, 80) |> with_window() |> with_file_tree(30)
      layout = Layout.compute(state)

      assert layout.file_tree == nil
      {_row, col, width, _h} = layout.editor_area
      assert col == 0
      assert width == 80
    end

    test "agent panel does not reserve BEAM rows" do
      state = new_state(24, 80) |> with_window() |> with_agent_panel()
      layout = Layout.compute(state)

      assert layout.agent_panel == nil
      assert layout.editor_area == {0, 0, 80, 24}
    end
  end

  # ── Splits (shared window-subdivision math) ──────────────────────────────────

  describe "compute/1 with vertical split" do
    test "two windows side by side without per-window modelines" do
      state = new_state(24, 80) |> with_vsplit()
      layout = Layout.compute(state)

      assert map_size(layout.window_layouts) == 2
      %{1 => left, 2 => right} = layout.window_layouts

      refute Map.has_key?(left, :modeline)
      refute Map.has_key?(right, :modeline)

      {_, _, _, left_h} = left.total
      {_, _, _, left_ch} = left.content
      assert left_h == left_ch

      {_, _, _, right_h} = right.total
      {_, _, _, right_ch} = right.content
      assert right_h == right_ch
    end
  end

  describe "compute/1 with horizontal split" do
    test "two windows stacked with a horizontal separator" do
      state = new_state(24, 80) |> with_hsplit()
      layout = Layout.compute(state)

      assert map_size(layout.window_layouts) == 2
      %{1 => top, 2 => bottom} = layout.window_layouts

      refute Map.has_key?(top, :modeline)

      assert [sep | _] = layout.horizontal_separators
      {sep_row, _sep_col, _sep_w, _sep_name} = sep

      {tr, _, _, th} = top.total
      assert sep_row == tr + th

      {br, _, _, _} = bottom.total
      assert br == sep_row + 1
    end
  end

  # ── Non-overlap invariant ────────────────────────────────────────────────────

  describe "non-overlap invariant" do
    test "no regions overlap in single window mode" do
      state = new_state(24, 80) |> with_window()
      assert_no_overlap(Layout.compute(state))
    end

    test "no regions overlap with vertical split" do
      state = new_state(24, 80) |> with_vsplit()
      assert_no_overlap(Layout.compute(state))
    end

    test "no regions overlap with horizontal split" do
      state = new_state(24, 80) |> with_hsplit()
      assert_no_overlap(Layout.compute(state))
    end
  end

  # ── Resize ───────────────────────────────────────────────────────────────────

  describe "resize" do
    test "layout adapts to new terminal size" do
      state = new_state(24, 80) |> with_window()
      layout1 = Layout.compute(state)

      vp = Viewport.new(40, 120)

      state2 =
        state
        |> then(fn state ->
          %{state | frontend: MingaEditor.State.Frontend.resize_terminal(state.frontend, vp)}
        end)

      layout2 = Layout.compute(state2)

      assert layout2.terminal == {0, 0, 120, 40}
      assert layout2.minibuffer == {40, 0, 120, 1}

      {_, _, w1, h1} = layout1.editor_area
      {_, _, w2, h2} = layout2.editor_area
      assert w2 > w1
      assert h2 > h1
    end
  end

  # ── Property-based tests ──────────────────────────────────────────────────────

  describe "property: no overlap for random configurations" do
    property "no regions overlap and no zero/negative dimensions for random terminal sizes" do
      check all(
              rows <- StreamData.integer(3..100),
              cols <- StreamData.integer(3..300),
              split_type <- StreamData.member_of([:none, :vertical, :horizontal])
            ) do
        state = new_state(rows, cols)

        state =
          case split_type do
            :none -> with_window(state)
            :vertical -> with_vsplit(state)
            :horizontal -> with_hsplit(state)
          end

        layout = Layout.compute(state)

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

        {_, _, ew, eh} = layout.editor_area
        assert ew > 0, "editor width must be positive, got #{ew}"
        assert eh > 0, "editor height must be positive, got #{eh}"

        assert_no_overlap(layout)
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp collect_all_rects(layout) do
    base = [layout.tab_bar, layout.status_bar, layout.minibuffer] |> Enum.reject(&is_nil/1)
    base = if layout.file_tree, do: [layout.file_tree | base], else: base
    base = if layout.agent_panel, do: [layout.agent_panel | base], else: base

    window_rects =
      layout.window_layouts
      |> Map.values()
      |> Enum.map(fn wl -> wl.content end)
      |> Enum.reject(fn {_r, _c, _w, h} -> h == 0 end)

    # Native chrome (the GUI minibuffer) renders outside the Metal grid, so its
    # rect is anchored on the row directly below the content and is not a grid
    # region. Drop off-grid rects from the grid-tiling invariants.
    {_tr, _tc, _tw, term_h} = layout.terminal

    (base ++ window_rects)
    |> Enum.reject(fn {r, _c, _w, _h} -> r >= term_h end)
  end

  defp assert_no_overlap(layout) do
    rects =
      [
        layout.tab_bar,
        layout.status_bar,
        layout.file_tree,
        layout.agent_panel,
        layout.minibuffer
      ]
      |> Enum.reject(&is_nil/1)

    window_rects =
      layout.window_layouts
      |> Map.values()
      |> Enum.map(fn wl -> wl.content end)
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

  # ── add_sidebar/1 (live shared helper) ───────────────────────────────────────

  describe "add_sidebar/1" do
    test "returns nil sidebar when window is too narrow" do
      layout = %{
        content: {0, 0, 80, 40},
        total: {0, 0, 80, 40},
        sidebar: nil
      }

      result = Layout.add_sidebar(layout)

      assert result.sidebar == nil
      assert result.content == {0, 0, 80, 40}
    end

    test "carves out sidebar when window exceeds threshold" do
      layout = %{
        content: {0, 0, 120, 40},
        total: {0, 0, 120, 40},
        sidebar: nil
      }

      result = Layout.add_sidebar(layout)

      {_, _, chat_w, _} = result.content
      {_, sidebar_col, sidebar_w, _} = result.sidebar

      assert chat_w + 1 + sidebar_w == 120
      assert sidebar_col == chat_w + 1
    end

    test "caps sidebar at one-third of window width" do
      layout = %{
        content: {0, 0, 90, 40},
        total: {0, 0, 90, 40},
        sidebar: nil
      }

      result = Layout.add_sidebar(layout)

      {_, _, sidebar_w, _} = result.sidebar
      assert sidebar_w == min(28, div(90, 3))
    end

    test "sidebar preserves row offset and height from content" do
      layout = %{
        content: {5, 10, 120, 30},
        total: {5, 10, 120, 30},
        sidebar: nil
      }

      result = Layout.add_sidebar(layout)

      {sr, _, _, sh} = result.sidebar
      {cr, _, _, ch} = result.content

      assert sr == cr
      assert sh == ch
    end
  end

  # ── GUI layout specifics ─────────────────────────────────────────────────────

  describe "GUI layout" do
    test "editor area starts at row 0 (no tab bar row)" do
      state = new_state(40, 120) |> with_window()
      layout = Layout.compute(state)

      {row, _col, _w, _h} = layout.editor_area
      assert row == 0
    end

    test "editor area uses the full viewport width" do
      state = new_state(40, 120) |> with_window()
      layout = Layout.compute(state)

      {_row, col, width, _h} = layout.editor_area
      assert col == 0
      assert width == 120
    end

    test "minibuffer is anchored just below the content grid (native chrome)" do
      state = new_state(40, 120) |> with_window()
      layout = Layout.compute(state)

      assert layout.minibuffer == {40, 0, 120, 1}
    end

    test "editor area height fills the full viewport (no phantom minibuffer row)" do
      state = new_state(40, 120) |> with_window()
      layout = Layout.compute(state)

      {_row, _col, _w, height} = layout.editor_area
      assert height == 40
    end

    test "tab bar, status bar, file tree, and agent panel rects are nil" do
      state = new_state(40, 120) |> with_window() |> with_file_tree(30) |> with_agent_panel()
      layout = Layout.compute(state)

      assert layout.tab_bar == nil
      assert layout.status_bar == nil
      assert layout.file_tree == nil
      assert layout.agent_panel == nil
    end

    test "single-window mode has no per-window modeline (status bar handles it)" do
      state = new_state(40, 120) |> with_window()
      layout = Layout.compute(state)

      win_layout = layout.window_layouts[1]
      refute Map.has_key?(win_layout, :modeline)
      assert win_layout.content == win_layout.total

      {_content_row, _c, _cw, content_h} = win_layout.content
      {_ea_row, _ea_c, _ea_w, ea_h} = layout.editor_area
      assert content_h == ea_h
    end

    test "split-window mode has no per-window modelines" do
      state = new_state(40, 120) |> with_vsplit()
      layout = Layout.compute(state)

      Enum.each(layout.window_layouts, fn {_id, wl} ->
        refute Map.has_key?(wl, :modeline)
      end)

      assert layout.status_bar == nil
    end
  end
end
