defmodule MingaEditor.FocusTree do
  @moduledoc """
  Tree of visible regions, built from the per-frame `Layout`.

  Mouse routing today is a flat hit-test stack: each input handler walks
  the layout rects asking "am I responsible?" and the order of checks
  encodes z-order implicitly. This module replaces that pattern with a
  single tree built once per frame; `hit_test/3` walks it top-down to
  find the deepest matching node, returning the node (and therefore its
  handler module).

  ## Tree shape

      viewport
      ├─ file_tree (when present)
      ├─ tab_bar (when present)
      ├─ editor_area
      │  ├─ window 1
      │  │  ├─ gutter
      │  │  ├─ buffer_content
      │  │  └─ modeline
      │  └─ window 2 (split, if any)
      ├─ agent_panel (when present)
      ├─ bottom_panel (when present)
      ├─ status_bar (when present)
      └─ minibuffer

  Modal overlays and floats are inserted at the end of the children
  list of the relevant parent node so the z-order resolves correctly:
  the last child whose rect contains the click wins.

  ## Status

  This PR introduces the data structure, the basic builder, and the
  `hit_test/3` API. Migration of the ad-hoc `inside_*?/2` predicates
  in `Input.{Picker, Completion, AgentMouse, FileTreeHandler}` to use
  the tree is staged as follow-up work — the existing predicates keep
  working because the tree is purely additive at this layer.
  """

  alias MingaEditor.FocusTree.Node, as: TreeNode
  alias MingaEditor.Layout

  @typedoc "Built focus tree, rooted at the viewport."
  @type t :: TreeNode.t()

  @doc """
  Builds a focus tree from a `Layout`. Pure; safe to call any time.

  Modal overlays, hover popups, and floats are added by the caller via
  `with_overlay/3` after construction so this function stays a pure
  layout-to-tree projection without coupling to shell state.
  """
  @spec from_layout(Layout.t()) :: t()
  def from_layout(%Layout{} = layout) do
    {tr, tc, tw, th} = layout.terminal

    # Children are listed in z-order from bottom (background) to top (overlays).
    # hit_test/3 reverses this list to give later children priority — that's
    # how file_tree paints over the editor_area at the same column range.
    children =
      []
      |> maybe_add(layout.tab_bar, &TreeNode.new(:tab_bar, &1))
      |> Kernel.++([editor_area_node(layout)])
      |> maybe_add(layout.file_tree, &TreeNode.new(:file_tree, &1))
      |> maybe_add(layout.agent_panel, &TreeNode.new(:agent_panel, &1))
      |> maybe_add(layout.status_bar, &TreeNode.new(:status_bar, &1))
      |> Kernel.++([TreeNode.new(:minibuffer, layout.minibuffer)])

    %TreeNode{
      content_type: :viewport,
      rect: {tr, tc, tw, th},
      handler: nil,
      scrollable?: false,
      focusable?: false,
      children: children
    }
  end

  @doc """
  Adds a modal/float overlay node to the tree. Inserted as the last
  child of the root so hit-tests resolve to it before the underlying
  editor regions.
  """
  @spec with_overlay(t(), TreeNode.content_type(), TreeNode.rect(), keyword()) :: t()
  def with_overlay(%TreeNode{children: children} = root, content_type, rect, opts \\ []) do
    overlay = TreeNode.new(content_type, rect, opts)
    %{root | children: children ++ [overlay]}
  end

  @doc """
  Hit-tests `(row, col)` against the tree. Returns the deepest node
  whose rect contains the point, or `nil` if no node matches.

  Children are searched in reverse order so later children (rendered
  on top) take precedence over earlier siblings.
  """
  @spec hit_test(t(), non_neg_integer(), non_neg_integer()) :: TreeNode.t() | nil
  def hit_test(%TreeNode{} = root, row, col) do
    if TreeNode.contains?(root, row, col) do
      child_hit =
        root.children
        |> Enum.reverse()
        |> Enum.find_value(fn child -> hit_test(child, row, col) end)

      child_hit || root
    else
      nil
    end
  end

  @doc """
  Walks from the deepest hit upward through the tree, yielding each
  ancestor node. Useful for "bubble" dispatch — try the deepest
  handler first, then bubble up if it returns `:passthrough`.

  Returns a list of nodes ordered from deepest to root. The flat
  hit-test stack (today's pattern) is equivalent to a one-element
  list when the deepest match is the only candidate.
  """
  @spec hit_path(t(), non_neg_integer(), non_neg_integer()) :: [TreeNode.t()]
  def hit_path(%TreeNode{} = root, row, col) do
    hit_path(root, row, col, [])
    |> Enum.reverse()
  end

  defp hit_path(%TreeNode{} = node, row, col, acc) do
    if TreeNode.contains?(node, row, col) do
      new_acc = [node | acc]
      deepest_child_path(node.children, row, col, new_acc) || new_acc
    else
      acc
    end
  end

  # Walks children in reverse z-order and returns the first child path that
  # extends beyond `acc` (i.e., a child whose subtree contained the point).
  # Returns `nil` when no child contained the point so the caller falls back
  # to its own `acc`.
  @spec deepest_child_path([TreeNode.t()], non_neg_integer(), non_neg_integer(), [TreeNode.t()]) ::
          [TreeNode.t()] | nil
  defp deepest_child_path(children, row, col, acc) do
    children
    |> Enum.reverse()
    |> Enum.find_value(fn child ->
      case hit_path(child, row, col, acc) do
        ^acc -> nil
        deeper -> deeper
      end
    end)
  end

  # ── Builders ───────────────────────────────────────────────────────────────

  defp editor_area_node(%Layout{editor_area: rect, window_layouts: windows}) do
    children =
      windows
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {win_id, wl} -> window_node(win_id, wl) end)

    TreeNode.new(:editor_area, rect, children: children)
  end

  defp window_node(win_id, win_layout) do
    children =
      [
        TreeNode.new(:buffer_content, win_layout.content,
          handler: nil,
          scrollable?: true,
          focusable?: true,
          ref: win_id
        )
      ]
      |> maybe_modeline(win_layout)

    TreeNode.new(:window, win_layout.total,
      ref: win_id,
      focusable?: true,
      children: children
    )
  end

  defp maybe_modeline(children, %{modeline: {_, _, _, 0}}), do: children

  defp maybe_modeline(children, %{modeline: rect}) do
    children ++ [TreeNode.new(:modeline, rect)]
  end

  defp maybe_add(children, nil, _build), do: children
  defp maybe_add(children, rect, build), do: children ++ [build.(rect)]
end
