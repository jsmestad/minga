defmodule MingaEditor.FocusTreeTest do
  @moduledoc """
  Tests for the focus tree built from `Layout`.

  Covers tree construction from realistic layouts, deepest-match
  hit-testing semantics, z-order overlay precedence, and boundary
  conditions (clicks exactly on rect edges).
  """

  use ExUnit.Case, async: true

  alias MingaEditor.FocusTree
  alias MingaEditor.FocusTree.Node, as: TreeNode
  alias MingaEditor.Layout
  alias MingaEditor.PickerUI
  alias MingaEditor.PickerUI.RenderInput
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
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
          content: {1, 0, 80, 21},
          modeline: {22, 0, 80, 0}
        }
      },
      horizontal_separators: [],
      agent_panel: nil,
      status_bar: {22, 0, 80, 1},
      minibuffer: {23, 0, 80, 1}
    }
  end

  defp split_layout do
    %Layout{
      terminal: {0, 0, 80, 24},
      tab_bar: {0, 0, 80, 1},
      editor_area: {1, 0, 80, 21},
      file_tree: {1, 0, 30, 21},
      window_layouts: %{
        1 => %{total: {1, 30, 25, 21}, content: {1, 30, 25, 21}, modeline: {22, 30, 25, 0}},
        2 => %{total: {1, 55, 25, 21}, content: {1, 55, 25, 21}, modeline: {22, 55, 25, 0}}
      },
      horizontal_separators: [],
      agent_panel: nil,
      status_bar: {22, 0, 80, 1},
      minibuffer: {23, 0, 80, 1}
    }
  end

  defp centered_picker_state(items, max_visible) do
    picker = Picker.new(items, title: "Models", max_visible: max_visible)

    %MingaEditor.State{
      port_manager: self(),
      workspace: %SessionState{viewport: Viewport.new(24, 80), editing: VimState.new()},
      layout: single_window_layout(),
      shell_state: %ShellState{
        modal:
          {:picker,
           PickerPayload.new(%PickerState{
             picker: picker,
             source: nil,
             layout: :centered
           })}
      }
    }
  end

  describe "from_layout/1" do
    test "produces a viewport-rooted tree with the canonical regions" do
      tree = FocusTree.from_layout(single_window_layout())

      assert tree.content_type == :viewport
      assert tree.rect == {0, 0, 80, 24}

      content_types = Enum.map(tree.children, & &1.content_type)
      # Order is editor_z (back-to-front): tab_bar, editor_area, status_bar, minibuffer.
      # file_tree, agent_panel only present when their rect is non-nil.
      assert :tab_bar in content_types
      assert :editor_area in content_types
      assert :status_bar in content_types
      assert :minibuffer in content_types
      refute :file_tree in content_types
      refute :agent_panel in content_types
    end

    test "skips nil chrome regions cleanly" do
      layout = %{single_window_layout() | tab_bar: nil, status_bar: nil}
      tree = FocusTree.from_layout(layout)

      content_types = Enum.map(tree.children, & &1.content_type)
      refute :tab_bar in content_types
      refute :status_bar in content_types
      assert :editor_area in content_types
      assert :minibuffer in content_types
    end

    test "editor_area carries one window child per window_layout entry" do
      tree = FocusTree.from_layout(split_layout())
      editor = Enum.find(tree.children, &(&1.content_type == :editor_area))

      assert length(editor.children) == 2
      assert Enum.all?(editor.children, &(&1.content_type == :window))
      refs = Enum.map(editor.children, & &1.ref)
      assert refs == [1, 2]
    end

    test "windows carry buffer_content children that are scrollable and focusable" do
      tree = FocusTree.from_layout(single_window_layout())
      editor = Enum.find(tree.children, &(&1.content_type == :editor_area))
      window = hd(editor.children)
      content = Enum.find(window.children, &(&1.content_type == :buffer_content))

      assert content.scrollable? == true
      assert content.focusable? == true
      assert content.ref == 1
    end

    test "zero-height modelines are not added as children" do
      tree = FocusTree.from_layout(single_window_layout())
      editor = Enum.find(tree.children, &(&1.content_type == :editor_area))
      window = hd(editor.children)

      refute Enum.any?(window.children, &(&1.content_type == :modeline))
    end
  end

  describe "hit_test/3 — deepest match" do
    test "returns the deepest matching node, not just the root" do
      tree = FocusTree.from_layout(single_window_layout())

      hit = FocusTree.hit_test(tree, 5, 40)
      # Inside the buffer content of window 1.
      assert hit.content_type == :buffer_content
      assert hit.ref == 1
    end

    test "click on tab bar resolves to :tab_bar" do
      tree = FocusTree.from_layout(single_window_layout())
      hit = FocusTree.hit_test(tree, 0, 5)
      assert hit.content_type == :tab_bar
    end

    test "click on minibuffer resolves to :minibuffer" do
      tree = FocusTree.from_layout(single_window_layout())
      hit = FocusTree.hit_test(tree, 23, 10)
      assert hit.content_type == :minibuffer
    end

    test "click outside the viewport returns nil" do
      tree = FocusTree.from_layout(single_window_layout())
      assert FocusTree.hit_test(tree, 100, 10) == nil
      assert FocusTree.hit_test(tree, 5, 200) == nil
    end

    test "split layout: click in left window resolves to that window's content" do
      tree = FocusTree.from_layout(split_layout())
      hit = FocusTree.hit_test(tree, 5, 40)
      assert hit.ref == 1
    end

    test "split layout: click in right window resolves to that window's content" do
      tree = FocusTree.from_layout(split_layout())
      hit = FocusTree.hit_test(tree, 5, 60)
      assert hit.ref == 2
    end

    test "click on file tree resolves to :file_tree (not the editor area below it)" do
      tree = FocusTree.from_layout(split_layout())
      hit = FocusTree.hit_test(tree, 5, 10)
      assert hit.content_type == :file_tree
    end
  end

  describe "hit_test/3 — boundary clicks" do
    test "click exactly at a rect's top-left corner is inside" do
      tree = FocusTree.from_layout(single_window_layout())
      # Tab bar starts at (0, 0).
      assert FocusTree.hit_test(tree, 0, 0).content_type == :tab_bar
    end

    test "click exactly at a rect's bottom-right edge is outside" do
      tree = FocusTree.from_layout(single_window_layout())
      # Terminal is {0, 0, 80, 24} → rows 0..23, cols 0..79.
      assert FocusTree.hit_test(tree, 24, 80) == nil
    end
  end

  describe "centered picker overlay height" do
    test "hit-test height matches the compact rendered popup height for tall lists" do
      items = for n <- 1..20, do: %Item{id: Integer.to_string(n), label: "model-#{n}"}
      picker = Picker.new(items, title: "Models", max_visible: 20)
      state = centered_picker_state(items, 20)

      {draws, _cursor} =
        PickerUI.render(%RenderInput{
          picker_state: %PickerState{picker: picker, source: nil, layout: :centered},
          theme_picker: Theme.get!(:doom_one).picker,
          viewport: Viewport.new(24, 80)
        })

      tree = FocusTree.from_state(state)
      picker_backdrop = Enum.find(tree.children, &(&1.content_type == :picker_backdrop))
      picker_node = hd(picker_backdrop.children)
      {box_row, _box_col, _box_w, box_h} = picker_node.rect

      box_draws =
        Enum.filter(draws, fn {row, col, text, _style} ->
          in_box = row >= box_row and row < box_row + box_h
          is_backdrop = col == 0 and String.length(text) == 80
          in_box and not is_backdrop
        end)

      rendered_rows = Enum.map(box_draws, fn {row, _col, _text, _style} -> row end)
      rendered_height = Enum.max(rendered_rows) - Enum.min(rendered_rows) + 1

      assert elem(picker_node.rect, 3) == rendered_height
    end
  end

  describe "with_overlay/3 — z-order" do
    test "an overlay added to the root takes precedence over underlying regions" do
      tree =
        single_window_layout()
        |> FocusTree.from_layout()
        |> FocusTree.with_overlay(:modal_overlay, {5, 10, 30, 10}, focusable?: true)

      hit = FocusTree.hit_test(tree, 8, 20)
      assert hit.content_type == :modal_overlay
    end

    test "clicks outside the overlay still resolve to underlying regions" do
      tree =
        single_window_layout()
        |> FocusTree.from_layout()
        |> FocusTree.with_overlay(:modal_overlay, {5, 10, 30, 10})

      hit = FocusTree.hit_test(tree, 0, 0)
      assert hit.content_type == :tab_bar
    end
  end

  describe "hit_path/3 — bubble dispatch" do
    test "returns nodes from deepest to root" do
      tree = FocusTree.from_layout(single_window_layout())
      path = FocusTree.hit_path(tree, 5, 40)

      types = Enum.map(path, & &1.content_type)
      assert types == [:buffer_content, :window, :editor_area, :viewport]
    end

    test "click on tab bar bubbles from tab bar to viewport" do
      tree = FocusTree.from_layout(single_window_layout())
      path = FocusTree.hit_path(tree, 0, 5)
      types = Enum.map(path, & &1.content_type)
      assert types == [:tab_bar, :viewport]
    end

    test "hit_test and hit_path agree on the deepest node" do
      tree = FocusTree.from_layout(single_window_layout())
      path = FocusTree.hit_path(tree, 5, 40)

      assert List.first(path) == FocusTree.hit_test(tree, 5, 40)
      assert Enum.all?(path, &TreeNode.contains?(&1, 5, 40))
    end
  end

  describe "node references" do
    test "children carry parent and sibling references" do
      tree = FocusTree.from_layout(split_layout())
      editor = Enum.find(tree.children, &(&1.content_type == :editor_area))
      [left, right] = editor.children

      assert editor.parent == :viewport
      assert left.parent == :editor_area
      assert left.previous_sibling == nil
      assert left.next_sibling == right.id
      assert right.previous_sibling == left.id
      assert right.next_sibling == nil
    end
  end

  describe "scroll_path/3" do
    test "starts at the deepest scrollable node under the cursor" do
      tree = FocusTree.from_layout(single_window_layout())
      path = FocusTree.scroll_path(tree, 5, 40)

      assert path |> List.first() |> Map.fetch!(:content_type) == :buffer_content

      assert Enum.map(path, & &1.content_type) == [
               :buffer_content,
               :window,
               :editor_area,
               :viewport
             ]
    end

    test "returns no route for non-scrollable chrome" do
      tree = FocusTree.from_layout(single_window_layout())
      assert FocusTree.scroll_path(tree, 0, 5) == []
    end
  end

  describe "Node.contains?/3" do
    test "inclusive-on-low, exclusive-on-high (half-open interval)" do
      node = TreeNode.new(:viewport, {2, 3, 5, 4})
      # Rows 2..5, cols 3..7
      assert TreeNode.contains?(node, 2, 3)
      assert TreeNode.contains?(node, 5, 7)
      refute TreeNode.contains?(node, 6, 5)
      refute TreeNode.contains?(node, 3, 8)
      refute TreeNode.contains?(node, 1, 5)
      refute TreeNode.contains?(node, 3, 2)
    end
  end
end
