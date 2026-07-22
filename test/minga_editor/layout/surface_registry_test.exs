defmodule MingaEditor.Layout.SurfaceRegistryTest do
  @moduledoc """
  Tests for the pure surface registry.

  The load-bearing guarantee (epic #2219 / #2268 AC-1) is behaviour
  neutrality: the registry rect for every placed surface equals the rect the
  focus tree (and therefore every hit-test routing through it) uses. We prove
  that by deriving both from the same layout and asserting agreement, plus the
  scope-honesty rule that only the single active overlay is placed.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.BottomPanel
  alias MingaEditor.FocusTree
  alias MingaEditor.Layout
  alias MingaEditor.Layout.SurfaceRegistry
  alias MingaEditor.Layout.SurfaceRegistry.Placement
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.VimState

  defp single_window_layout do
    %Layout{
      terminal: {0, 0, 80, 24},
      tab_bar: {0, 0, 80, 1},
      editor_area: {1, 0, 80, 21},
      file_tree: nil,
      window_layouts: %{
        1 => %{
          total: {1, 0, 80, 21},
          content: {1, 0, 80, 21}
        }
      },
      horizontal_separators: [],
      agent_panel: nil,
      status_bar: {22, 0, 80, 1},
      minibuffer: {23, 0, 80, 1}
    }
  end

  defp tree_nodes(%{children: children} = node) do
    [node | Enum.flat_map(children, &tree_nodes/1)]
  end

  defp split_layout do
    %Layout{
      terminal: {0, 0, 80, 24},
      tab_bar: {0, 0, 80, 1},
      editor_area: {1, 0, 80, 21},
      file_tree: {1, 0, 30, 21},
      window_layouts: %{
        1 => %{total: {1, 30, 25, 21}, content: {1, 30, 25, 21}},
        2 => %{total: {1, 55, 25, 21}, content: {1, 55, 25, 21}}
      },
      horizontal_separators: [],
      agent_panel: nil,
      status_bar: {22, 0, 80, 1},
      minibuffer: {23, 0, 80, 1}
    }
  end

  defp placements_from_layout(layout) do
    layout
    |> FocusTree.from_layout()
    |> SurfaceRegistry.from_tree()
  end

  describe "placements/from_tree" do
    test "enumerates the canonical chrome surfaces with rects from the layout" do
      placements = placements_from_layout(single_window_layout())
      by_id = Map.new(placements, &{&1.surface_id, &1})

      assert by_id[:tab_bar].rect == {0, 0, 80, 1}
      assert by_id[:editor_area].rect == {1, 0, 80, 21}
      assert by_id[:buffer_content].rect == {1, 0, 80, 21}
      assert by_id[:status_bar].rect == {22, 0, 80, 1}
      assert by_id[:minibuffer].rect == {23, 0, 80, 1}
    end

    test "skips nil chrome regions" do
      layout = %{single_window_layout() | tab_bar: nil, status_bar: nil}
      ids = layout |> placements_from_layout() |> Enum.map(& &1.surface_id)

      refute :tab_bar in ids
      refute :status_bar in ids
      assert :editor_area in ids
      assert :minibuffer in ids
    end

    test "the viewport root and window containers are not placed surfaces" do
      ids = single_window_layout() |> placements_from_layout() |> Enum.map(& &1.surface_id)

      refute :viewport in ids
      refute :window in ids
    end

    test "ordering is back-to-front by z (non-decreasing)" do
      zs = single_window_layout() |> placements_from_layout() |> Enum.map(& &1.z)
      assert zs == Enum.sort(zs)
    end

    test "every placement carries a hit_kind" do
      placements = single_window_layout() |> placements_from_layout()

      assert Enum.all?(placements, fn %Placement{hit_kind: k} ->
               k in [
                 :text,
                 :gutter,
                 :fold_control,
                 :status_bar,
                 :divider,
                 :chrome,
                 :overlay
               ]
             end)

      buffer = Enum.find(placements, &(&1.surface_id == :buffer_content))
      assert buffer.hit_kind == :text
    end
  end

  # ── Behaviour neutrality: registry rect == focus-tree hit-test rect ──────────

  describe "registry rect equals focus-tree hit-test rect (AC-1)" do
    test "single-window layout: each placed surface's rect contains a hit that resolves to it" do
      layout = single_window_layout()
      tree = FocusTree.from_layout(layout)
      placements = SurfaceRegistry.from_tree(tree)

      # tab_bar surface rect: the focus-tree node hit at the surface origin must
      # have the same rect the registry placed.
      assert_surface_rect_matches_tree(tree, placements, :tab_bar)
      assert_surface_rect_matches_tree(tree, placements, :status_bar)
      assert_surface_rect_matches_tree(tree, placements, :minibuffer)
      assert_surface_rect_matches_tree(tree, placements, :buffer_content)
    end

    test "split layout: one buffer_content placement per window, distinct rects" do
      # Surface ids repeat deliberately in splits: each window's content is a
      # real, independently placed surface. The future emitter ships one
      # placement per window; rect_for_in/2 takes the topmost by z for
      # single-rect consumers.
      layout = split_layout()
      tree = FocusTree.from_layout(layout)
      placements = SurfaceRegistry.from_tree(tree)

      content_placements =
        Enum.filter(placements, &(&1.surface_id == :buffer_content))

      window_count =
        tree
        |> tree_nodes()
        |> Enum.count(&(&1.content_type == :window))

      assert window_count > 1
      assert Enum.count(content_placements) == window_count

      rects = Enum.map(content_placements, & &1.rect)
      assert Enum.count(Enum.uniq(rects)) == Enum.count(rects)
    end

    test "split layout: sidebar rect resolves via hit-test and agrees with the tree" do
      layout = split_layout()
      tree = FocusTree.from_layout(layout)
      placements = SurfaceRegistry.from_tree(tree)

      assert_surface_rect_matches_tree(tree, placements, :sidebar)
    end

    test "split layout: editor area rect equals the tree node rect (even when occluded at its origin)" do
      # The sidebar overlays the editor area's top-left, so a hit at the editor
      # area origin resolves to the sidebar. The registry rect must still equal
      # the focus tree's editor_area node rect: same authoritative source.
      layout = split_layout()
      tree = FocusTree.from_layout(layout)
      placements = SurfaceRegistry.from_tree(tree)

      registry_rect = SurfaceRegistry.rect_for_in(placements, :editor_area)
      tree_node = Enum.find(tree.children, &(&1.content_type == :editor_area))

      assert registry_rect == tree_node.rect
    end

    test "rect_for_in returns the placed rect a hit-tester would read" do
      placements = placements_from_layout(single_window_layout())
      assert SurfaceRegistry.rect_for_in(placements, :tab_bar) == {0, 0, 80, 1}
      assert SurfaceRegistry.rect_for_in(placements, :status_bar) == {22, 0, 80, 1}
      assert SurfaceRegistry.rect_for_in(placements, :file_tree) == nil
    end

    test "within?/contains? matches FocusTree.Node half-open containment" do
      assert SurfaceRegistry.contains?({0, 0, 80, 1}, 0, 0)
      assert SurfaceRegistry.contains?({0, 0, 80, 1}, 0, 79)
      refute SurfaceRegistry.contains?({0, 0, 80, 1}, 0, 80)
      refute SurfaceRegistry.contains?({0, 0, 80, 1}, 1, 0)
    end

    # For each placed surface, hit the focus tree at the surface's top-left
    # cell. The deepest tree node whose content_type maps back to that surface
    # must carry the exact rect the registry placed. This is the "one source,
    # test-proven" guarantee.
    defp assert_surface_rect_matches_tree(tree, placements, surface_id) do
      rect = SurfaceRegistry.rect_for_in(placements, surface_id)
      assert rect, "expected #{surface_id} to be placed"

      {r, c, _w, _h} = rect
      path = FocusTree.hit_path(tree, r, c)

      tree_node =
        Enum.find(path, fn node ->
          SurfaceRegistry.surface_id(node.content_type) == surface_id
        end)

      assert tree_node,
             "expected focus-tree hit at (#{r},#{c}) to include a #{surface_id} node"

      assert tree_node.rect == rect,
             "registry rect #{inspect(rect)} != focus-tree rect #{inspect(tree_node.rect)} for #{surface_id}"
    end
  end

  # ── Scope honesty: single active overlay only ───────────────────────────────

  describe "single active overlay (AC-4)" do
    test "with a bottom panel visible, the panel is placed as floating chrome above the editor" do
      state = %MingaEditor.State{
        frontend: %MingaEditor.State.Frontend{port_manager: self()},
        workspace: %SessionState{editing: VimState.new()},
        render: %MingaEditor.State.Render{layout: single_window_layout()},
        shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            %ShellState{bottom_panel: %BottomPanel{visible: true, height_percent: 25}}
          )
      }

      placements = SurfaceRegistry.placements(state)
      by_id = Map.new(placements, &{&1.surface_id, &1})

      assert panel = by_id[:bottom_panel]
      assert panel.z > by_id[:editor_area].z
    end

    test "no modal active: no overlay surfaces are placed" do
      placements = placements_from_layout(single_window_layout())
      overlay_ids = [:picker, :picker_backdrop, :completion_menu, :completion_backdrop]
      assert Enum.all?(placements, &(&1.surface_id not in overlay_ids))
    end
  end

  # ── Wire mapping coordination point (#2264) ─────────────────────────────────

  describe "surface_id_u16 mapping" do
    test "maps each placed surface id to a stable, unique u16" do
      ids = [
        :editor_area,
        :tab_bar,
        :buffer_content,
        :agent_chat_content,
        :file_tree,
        :sidebar,
        :custom_sidebar,
        :agent_panel,
        :status_bar,
        :minibuffer,
        :bottom_panel,
        :picker_backdrop,
        :picker,
        :completion_backdrop,
        :completion_menu
      ]

      u16s = Enum.map(ids, &SurfaceRegistry.surface_id_u16/1)

      assert Enum.all?(u16s, &(&1 in 0..65_535))
      assert Enum.count(Enum.uniq(u16s)) == Enum.count(u16s), "surface_id_u16 must be injective"
    end
  end
end
