defmodule MingaEditor.FocusTree do
  @moduledoc """
  Tree of visible regions, built from the per-frame `Layout` plus active overlays.

  Mouse routing uses this tree instead of asking every handler to re-check screen coordinates. Hit-testing finds the deepest visible node at a position, and the router dispatches to that node's handler before bubbling to ancestors when a handler returns `{:passthrough, state}`.

  Children are stored in rendered z-order from back to front. Hit-tests walk children in reverse order, so later siblings win when regions overlap.
  """

  alias Minga.Buffer
  alias Minga.Editing.Completion
  alias MingaEditor.BottomPanel
  alias MingaEditor.CompletionUI
  alias MingaEditor.FocusTree.Node, as: TreeNode
  alias MingaEditor.HoverPopup
  alias MingaEditor.HoverPopup.Presenter, as: HoverPresenter
  alias MingaEditor.Input
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.Layout.FooterOverlays
  alias MingaEditor.Layout.OverlayBand
  alias MingaEditor.SignatureHelp
  alias MingaEditor.SignatureHelp.Presenter, as: SignatureHelpPresenter
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Frontend, as: FrontendState
  alias MingaEditor.RenderPipeline.Input, as: RenderInput
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.UI.Picker, as: PickerData
  alias MingaEditor.Viewport
  alias MingaEditor.Window.Content

  @typedoc "Built focus tree, rooted at the viewport."
  @type t :: TreeNode.t()

  @typedoc "Mouse route ordered from deepest target to root for bubbling."
  @type path :: [TreeNode.t()]

  @doc "Returns the cached focus tree from state, or builds one from the current state."
  @spec get(map()) :: t()
  def get(%{render: %{focus_tree: %TreeNode{} = cached}}), do: cached
  def get(%{focus_tree: %TreeNode{} = cached}), do: cached
  def get(state), do: from_state(state)

  @doc "Builds a focus tree from editor or render-pipeline state."
  @spec from_state(map()) :: t()
  def from_state(state) do
    layout = Layout.get(state)

    layout
    |> build_base(window_map(state), Input.editing_dispatch_handler(state), state)
    |> add_footer_band_overlays(state, layout)
    |> add_floating_overlays(state)
    |> add_modal_overlays(state, layout)
    |> link_tree()
  end

  @doc "Builds a focus tree from a `Layout`. Pure; safe to call any time."
  @spec from_layout(Layout.t()) :: t()
  def from_layout(%Layout{} = layout) do
    layout
    |> build_base(%{}, Input.ModeFSM, nil)
    |> link_tree()
  end

  @doc "Adds a modal or float overlay node to the root in front of existing regions."
  @spec with_overlay(t(), TreeNode.content_type(), TreeNode.rect(), keyword()) :: t()
  def with_overlay(%TreeNode{children: children} = root, content_type, rect, opts \\ []) do
    overlay = TreeNode.new(content_type, rect, opts)
    %{root | children: Enum.concat(children, [overlay])} |> link_tree()
  end

  @doc "Hit-tests `(row, col)` and returns the deepest node whose rect contains the point."
  @spec hit_test(t(), integer(), integer()) :: TreeNode.t() | nil
  def hit_test(%TreeNode{} = root, row, col) do
    root
    |> hit_path(row, col)
    |> List.first()
  end

  @doc "Returns the bubble path ordered from deepest node to root."
  @spec hit_path(t(), integer(), integer()) :: path()
  def hit_path(%TreeNode{} = root, row, col) do
    do_hit_path(root, row, col)
  end

  @doc "Returns the path starting at the deepest scrollable node under `(row, col)`."
  @spec scroll_path(t(), integer(), integer()) :: path()
  def scroll_path(%TreeNode{} = root, row, col) do
    path = hit_path(root, row, col)

    case Enum.find_index(path, & &1.scrollable?) do
      nil -> []
      index -> Enum.drop(path, index)
    end
  end

  @doc "Links parent and sibling references throughout a tree."
  @spec link_tree(t()) :: t()
  def link_tree(%TreeNode{} = root) do
    link_node(%{root | parent: nil, previous_sibling: nil, next_sibling: nil}, nil, nil, nil)
  end

  @spec do_hit_path(TreeNode.t(), integer(), integer()) :: path()
  defp do_hit_path(%TreeNode{} = node, row, col) do
    if TreeNode.contains?(node, row, col) do
      node.children
      |> deepest_child_path(row, col)
      |> append_node_to_path(node)
    else
      []
    end
  end

  @spec deepest_child_path([TreeNode.t()], integer(), integer()) :: path() | nil
  defp deepest_child_path(children, row, col) do
    children
    |> Enum.reverse()
    |> Enum.find_value(fn child ->
      case do_hit_path(child, row, col) do
        [] -> nil
        path -> path
      end
    end)
  end

  @spec append_node_to_path(path() | nil, TreeNode.t()) :: path()
  defp append_node_to_path(nil, node), do: [node]
  defp append_node_to_path(path, node), do: Enum.concat(path, [node])

  @spec link_node(TreeNode.t(), TreeNode.id() | nil, TreeNode.id() | nil, TreeNode.id() | nil) ::
          TreeNode.t()
  defp link_node(%TreeNode{} = node, parent, previous_sibling, next_sibling) do
    linked_children = link_children(node.children, node.id)

    %{
      node
      | parent: parent,
        previous_sibling: previous_sibling,
        next_sibling: next_sibling,
        children: linked_children
    }
  end

  @spec link_children([TreeNode.t()], TreeNode.id()) :: [TreeNode.t()]
  defp link_children(children, parent_id) do
    ids = Enum.map(children, & &1.id)

    children
    |> Enum.with_index()
    |> Enum.map(fn {child, index} ->
      previous_id = sibling_id(ids, index - 1)
      next_id = sibling_id(ids, index + 1)
      link_node(child, parent_id, previous_id, next_id)
    end)
  end

  @spec sibling_id([TreeNode.id()], integer()) :: TreeNode.id() | nil
  defp sibling_id(ids, index) when index >= 0, do: Enum.at(ids, index)
  defp sibling_id(_ids, _index), do: nil

  # ── Builders ───────────────────────────────────────────────────────────────

  @spec window_map(map()) :: map()
  defp window_map(%{workspace: %{windows: %{map: map}}}) when is_map(map), do: map
  defp window_map(_state), do: %{}

  @spec build_base(Layout.t(), map(), module(), map() | nil) :: t()
  defp build_base(%Layout{} = layout, window_map, bottom_handler, state) do
    {tr, tc, tw, th} = layout.terminal

    children =
      []
      |> maybe_add(layout.tab_bar, &TreeNode.new(:tab_bar, &1, handler: bottom_handler))
      |> Kernel.++([editor_area_node(layout, window_map, bottom_handler)])
      |> maybe_add(layout.file_tree, &file_tree_node(&1, state))
      |> maybe_add(layout.agent_panel, &agent_panel_node/1)
      |> maybe_add(layout.status_bar, &TreeNode.new(:status_bar, &1, handler: bottom_handler))
      |> Kernel.++([TreeNode.new(:minibuffer, layout.minibuffer, handler: bottom_handler)])
      |> maybe_add(bottom_panel_rect(layout, state), &bottom_panel_node/1)

    %TreeNode{
      id: :viewport,
      content_type: :viewport,
      rect: {tr, tc, tw, th},
      handler: nil,
      scrollable?: false,
      focusable?: false,
      children: children
    }
  end

  @spec bottom_panel_rect(Layout.t(), map() | nil) :: Layout.rect() | nil
  defp bottom_panel_rect(_layout, nil), do: nil

  defp bottom_panel_rect(
         %Layout{} = layout,
         %{
           shell_runtime: %{
             state: %{
               bottom_panel: %BottomPanel{visible: true, height_percent: height_percent}
             }
           }
         }
       ),
       do: bottom_panel_rect(layout, height_percent)

  defp bottom_panel_rect(
         %Layout{} = layout,
         %{
           shell_state: %{
             bottom_panel: %BottomPanel{visible: true, height_percent: height_percent}
           }
         }
       ),
       do: bottom_panel_rect(layout, height_percent)

  @spec bottom_panel_rect(Layout.t(), non_neg_integer()) :: Layout.rect()
  defp bottom_panel_rect(
         %Layout{terminal: {row, col, width, rows}},
         height_percent
       )
       when is_integer(height_percent) and height_percent >= 0 do
    panel_height = bottom_panel_height(rows, height_percent)
    {row + rows - panel_height, col, width, panel_height}
  end

  defp bottom_panel_rect(_layout, _state), do: nil

  @spec bottom_panel_height(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp bottom_panel_height(rows, height_percent) do
    max_height = max(rows - 1, 1)
    percent = height_percent |> max(1) |> min(100)

    rows
    |> Kernel.*(percent)
    |> div(100)
    |> max(4)
    |> min(max_height)
  end

  @spec bottom_panel_node(Layout.rect()) :: TreeNode.t()
  defp bottom_panel_node(rect) do
    TreeNode.new(:bottom_panel, rect,
      handler: Input.BottomPanel,
      scrollable?: true,
      focusable?: true
    )
  end

  @spec file_tree_node(Layout.rect(), map() | nil) :: TreeNode.t()
  defp file_tree_node(rect, state) do
    case active_left_sidebar(state) do
      %{id: "file_tree", input_handler: handler, source: source} ->
        TreeNode.new(:file_tree, rect,
          id: {:sidebar, "file_tree"},
          ref: "file_tree",
          handler: handler || Input.FileTreeHandler,
          source: source,
          scrollable?: true,
          focusable?: true
        )

      %{id: id, input_handler: handler, source: source} ->
        TreeNode.new({:custom, :sidebar}, rect,
          id: {:sidebar, id},
          ref: id,
          handler: handler || Input.Sidebar,
          source: source,
          scrollable?: true,
          focusable?: true
        )

      nil ->
        TreeNode.new(:sidebar, rect,
          handler: Input.Sidebar,
          scrollable?: true,
          focusable?: true
        )
    end
  end

  @spec active_left_sidebar(map() | nil) :: Sidebar.entry() | nil
  defp active_left_sidebar(nil), do: nil
  defp active_left_sidebar(state), do: Sidebar.active_left(Sidebar.table_for(state))

  @spec agent_panel_node(Layout.rect()) :: TreeNode.t()
  defp agent_panel_node(rect) do
    TreeNode.new(:agent_panel, rect,
      handler: Input.AgentMouse,
      scrollable?: true,
      focusable?: true
    )
  end

  @spec editor_area_node(Layout.t(), map(), module()) :: TreeNode.t()
  defp editor_area_node(
         %Layout{editor_area: rect, window_layouts: windows},
         window_map,
         bottom_handler
       ) do
    children =
      windows
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {win_id, wl} ->
        window_node(win_id, wl, Map.get(window_map, win_id), bottom_handler)
      end)

    TreeNode.new(:editor_area, rect, handler: bottom_handler, children: children)
  end

  @spec window_node(term(), Layout.window_layout(), term(), module()) :: TreeNode.t()
  defp window_node(win_id, win_layout, window, bottom_handler) do
    agent_chat? = agent_chat_window?(window)
    window_type = if agent_chat?, do: :agent_chat_window, else: :window
    content_type = if agent_chat?, do: :agent_chat_content, else: :buffer_content
    content_handler = if agent_chat?, do: Input.AgentMouse, else: bottom_handler

    children =
      [
        TreeNode.new(content_type, win_layout.content,
          handler: content_handler,
          scrollable?: true,
          focusable?: true,
          ref: win_id
        )
      ]
      |> maybe_modeline(win_layout, win_id)

    TreeNode.new(window_type, win_layout.total,
      ref: win_id,
      focusable?: true,
      handler: bottom_handler,
      children: children
    )
  end

  @spec agent_chat_window?(term()) :: boolean()
  defp agent_chat_window?(%{content: content}), do: Content.agent_chat?(content)
  defp agent_chat_window?(_window), do: false

  @spec maybe_modeline([TreeNode.t()], Layout.window_layout(), term()) :: [TreeNode.t()]
  defp maybe_modeline(children, %{modeline: {_, _, _, 0}}, _win_id), do: children

  defp maybe_modeline(children, %{modeline: rect}, win_id) do
    Enum.concat(children, [TreeNode.new(:modeline, rect, handler: Input.ModeFSM, ref: win_id)])
  end

  @spec maybe_add([TreeNode.t()], Layout.rect() | nil, (Layout.rect() -> TreeNode.t())) ::
          [TreeNode.t()]
  defp maybe_add(children, nil, _build), do: children
  defp maybe_add(children, rect, build), do: Enum.concat(children, [build.(rect)])

  # ── Footer-band overlay builders ──────────────────────────────────────────
  #
  # The seven active secondary overlay producers (float popup, agent context,
  # extension panel, observatory, edit timeline, notifications, extension overlay)
  # the owner ruled mouse-driven (#2330). `FooterOverlays.visible/1`
  # decides which are live this frame (single-active model still holds, but the
  # tree expresses each visible one so the registry/emitter carry their rect/z;
  # Go composites the single highest-z winner). Each gets a bottom-anchored band
  # rect from `OverlayBand` and the `Input.OverlaySink` handler so a click or
  # scroll over a visible overlay is swallowed instead of bubbling to the buffer
  # (AC-2). Per-surface activation semantics replace the sink via epic #2330
  # children.
  #
  # Ordering matters for the hit-test. `FooterOverlays.visible/1` returns entries
  # in ASCENDING z (back-to-front); this reduce appends them as root children in
  # that order, so the highest-z overlay is the LAST child. `do_hit_path` reverses
  # children before searching, so the last child (highest z) wins among same-rect
  # siblings, making the BEAM hit-winner the SAME surface Go composites on top (its
  # highest-z render winner). Inverting the order here would let the lowest-z node
  # win the hit-test against the render winner, which the #2330 per-surface handlers
  # must not see.

  @spec add_footer_band_overlays(t(), map(), Layout.t()) :: t()
  defp add_footer_band_overlays(%TreeNode{} = root, state, %Layout{terminal: terminal}) do
    state
    |> FooterOverlays.visible()
    |> Enum.reduce(root, fn {surface_id, content_height}, acc ->
      case OverlayBand.rect(terminal, content_height) do
        nil -> acc
        rect -> append_root_child(acc, footer_overlay_node(surface_id, rect))
      end
    end)
  end

  @spec footer_overlay_node(atom(), Layout.rect()) :: TreeNode.t()
  defp footer_overlay_node(surface_id, rect) do
    TreeNode.new(surface_id, rect,
      handler: Input.OverlaySink,
      scrollable?: true,
      focusable?: true
    )
  end

  # ── Floating overlay builders ─────────────────────────────────────────────
  #
  # Cursor-anchored LSP popups (hover, signature help). Their rect is a
  # conservative BEAM cell-grid containment/fallback rect for focus routing and
  # terminal-style surfaces. Native GUI frontends render these popups from
  # semantic opcode content and own final pixel placement because it depends on
  # font metrics, measured content, chrome insets, and viewport points. They sit
  # ABOVE floating chrome (bottom panel) and BELOW the single active modal
  # overlay, preserving the historical stacking order.

  @spec add_floating_overlays(t(), map()) :: t()
  defp add_floating_overlays(%TreeNode{} = root, state) do
    root
    |> maybe_add_hover_overlay(state)
    |> maybe_add_signature_overlay(state)
  end

  @spec maybe_add_hover_overlay(t(), map()) :: t()
  defp maybe_add_hover_overlay(%TreeNode{} = root, %{
         shell_runtime: %{state: shell_state},
         frontend: %{terminal_viewport: vp}
       }) do
    maybe_add_hover_overlay(root, %{shell_state: shell_state, terminal_viewport: vp})
  end

  defp maybe_add_hover_overlay(%TreeNode{} = root, %{
         shell_runtime: %{state: shell_state},
         terminal_viewport: vp
       }) do
    maybe_add_hover_overlay(root, %{shell_state: shell_state, terminal_viewport: vp})
  end

  defp maybe_add_hover_overlay(%TreeNode{} = root, %{
         shell_state: %{hover_popup: %HoverPopup{} = popup},
         terminal_viewport: vp
       }) do
    case HoverPresenter.box(popup, {vp.rows, vp.cols}) do
      nil ->
        root

      rect ->
        append_root_child(
          root,
          TreeNode.new(:hover_popup, rect,
            handler: Input.Hover,
            scrollable?: true,
            focusable?: true
          )
        )
    end
  end

  defp maybe_add_hover_overlay(%TreeNode{} = root, _state), do: root

  @spec maybe_add_signature_overlay(t(), map()) :: t()
  defp maybe_add_signature_overlay(%TreeNode{} = root, %{
         shell_runtime: %{state: shell_state},
         frontend: %{terminal_viewport: vp}
       }) do
    maybe_add_signature_overlay(root, %{
      shell_state: shell_state,
      terminal_viewport: vp
    })
  end

  defp maybe_add_signature_overlay(%TreeNode{} = root, %{
         shell_runtime: %{state: shell_state},
         terminal_viewport: vp
       }) do
    maybe_add_signature_overlay(root, %{
      shell_state: shell_state,
      terminal_viewport: vp
    })
  end

  defp maybe_add_signature_overlay(%TreeNode{} = root, %{
         shell_state: %{signature_help: %SignatureHelp{} = sh},
         terminal_viewport: vp
       }) do
    case SignatureHelpPresenter.box(sh, {vp.rows, vp.cols}) do
      nil ->
        root

      rect ->
        append_root_child(
          root,
          TreeNode.new(:signature_help, rect, handler: Input.SignatureHelp)
        )
    end
  end

  defp maybe_add_signature_overlay(%TreeNode{} = root, _state), do: root

  # ── Overlay builders ──────────────────────────────────────────────────────

  @spec add_modal_overlays(t(), map(), Layout.t()) :: t()
  defp add_modal_overlays(
         %TreeNode{} = root,
         %{shell_runtime: %{state: %{modal: {:picker, payload}}}},
         layout
       ) do
    add_picker_overlay(root, payload.picker_ui, layout)
  end

  defp add_modal_overlays(
         %TreeNode{} = root,
         %{shell_state: %{modal: {:picker, payload}}},
         layout
       ) do
    add_picker_overlay(root, payload.picker_ui, layout)
  end

  defp add_modal_overlays(%TreeNode{} = root, state, layout) do
    case MingaEditor.Shell.Traditional.ModalWorkflow.completion(state) do
      %Completion{} = completion -> add_completion_overlay(root, completion, state, layout)
      _ -> root
    end
  end

  @spec add_picker_overlay(t(), map(), Layout.t()) :: t()
  defp add_picker_overlay(
         %TreeNode{} = root,
         %{picker: %PickerData{} = picker, layout: :centered},
         layout
       ) do
    backdrop =
      TreeNode.new(:picker_backdrop, layout.terminal,
        handler: Input.Picker,
        scrollable?: true,
        children: [
          TreeNode.new(:picker, centered_picker_rect(layout, picker),
            handler: Input.Picker,
            scrollable?: true,
            focusable?: true
          )
        ]
      )

    append_root_child(root, backdrop)
  end

  defp add_picker_overlay(%TreeNode{} = root, %{picker: %PickerData{} = picker}, layout) do
    backdrop =
      TreeNode.new(:picker_backdrop, layout.terminal,
        handler: Input.Picker,
        scrollable?: true,
        children: [
          TreeNode.new(:picker, bottom_picker_rect(layout, picker),
            handler: Input.Picker,
            scrollable?: true,
            focusable?: true
          )
        ]
      )

    append_root_child(root, backdrop)
  end

  defp add_picker_overlay(%TreeNode{} = root, _picker_state, _layout), do: root

  @spec add_completion_overlay(t(), Completion.t(), map(), Layout.t()) :: t()
  defp add_completion_overlay(%TreeNode{} = root, completion, state, layout) do
    case CompletionUI.menu_rect(completion, completion_render_opts(state, layout)) do
      nil ->
        root

      rect ->
        backdrop =
          TreeNode.new(:completion_backdrop, layout.terminal,
            handler: Input.Completion,
            scrollable?: true,
            children: [
              TreeNode.new(:completion_menu, rect,
                handler: Input.Completion,
                scrollable?: true,
                focusable?: true
              )
            ]
          )

        append_root_child(root, backdrop)
    end
  end

  @spec append_root_child(t(), TreeNode.t()) :: t()
  defp append_root_child(%TreeNode{children: children} = root, child) do
    %{root | children: Enum.concat(children, [child])}
  end

  @spec centered_picker_rect(Layout.t(), PickerData.t()) :: Layout.rect()
  defp centered_picker_rect(%Layout{terminal: {_row, _col, cols, rows}}, picker) do
    max_height = max(div(rows * 70, 100), 5)
    item_capacity = max_height - 3
    {visible, _selected_offset} = PickerData.visible_items(picker, item_capacity)
    width = max(div(cols * 60, 100), 1)
    height = min(Enum.count(visible) + 3, max_height) |> min(rows) |> max(1)
    row = max(div(rows - height, 2), 0)
    col = max(div(cols - width, 2), 0)
    {row, col, width, height}
  end

  @spec bottom_picker_rect(Layout.t(), PickerData.t()) :: Layout.rect()
  defp bottom_picker_rect(%Layout{terminal: {_row, _col, cols, rows}}, picker) do
    {visible, _selected_offset} = PickerData.visible_items(picker, max(rows - 3, 1))
    item_count = Enum.count(visible)
    prompt_row = rows - 1
    separator_row = prompt_row - item_count - 1
    first_row = max(separator_row, 0)
    height = max(prompt_row - first_row + 1, 1)
    {first_row, 0, cols, height}
  end

  @spec completion_render_opts(EditorState.t() | RenderInput.t(), Layout.t()) ::
          CompletionUI.render_opts()
  defp completion_render_opts(state, layout) do
    {cursor_row, cursor_col} = cursor_screen_pos(state, layout)
    viewport = terminal_viewport(state)

    %{
      cursor_row: cursor_row,
      cursor_col: cursor_col,
      viewport_rows: viewport.rows,
      viewport_cols: viewport.cols
    }
  end

  @spec terminal_viewport(EditorState.t() | RenderInput.t()) :: Viewport.t()
  defp terminal_viewport(%EditorState{frontend: %FrontendState{terminal_viewport: viewport}}),
    do: viewport

  defp terminal_viewport(%RenderInput{terminal_viewport: viewport}), do: viewport

  @spec cursor_screen_pos(map(), Layout.t()) :: {non_neg_integer(), non_neg_integer()}
  defp cursor_screen_pos(%{workspace: %{buffers: %{active: buf}}} = state, layout)
       when is_pid(buf) do
    {line, col} = Buffer.cursor(buf)
    total_lines = Buffer.line_count(buf)
    line_number_style = Buffer.get_option(buf, :line_numbers)
    number_width = if line_number_style == :none, do: 0, else: Viewport.gutter_width(total_lines)
    gutter_width = Gutter.total_width(number_width)

    state
    |> cursor_origin(layout)
    |> cursor_screen_pos_from_origin(line, col, gutter_width)
  catch
    :exit, _ -> {0, 0}
  end

  defp cursor_screen_pos(_state, _layout), do: {0, 0}

  @spec cursor_origin(EditorState.t() | RenderInput.t(), Layout.t()) ::
          {integer(), integer(), non_neg_integer(), non_neg_integer()}
  defp cursor_origin(state, layout) do
    with %{content: {row, col, _width, _height}} <- active_window_layout(layout, state),
         %{viewport: viewport} <- active_window(state) do
      {row, col, viewport.top, viewport.left}
    else
      _ ->
        viewport = terminal_viewport(state)
        {0, 0, viewport.top, viewport.left}
    end
  end

  @spec cursor_screen_pos_from_origin(
          {integer(), integer(), non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {non_neg_integer(), non_neg_integer()}
  defp cursor_screen_pos_from_origin({row, col, top, left}, line, cursor_col, gutter_width) do
    screen_row = row + line - top
    screen_col = col + cursor_col + gutter_width - left
    {max(screen_row, 0), max(screen_col, 0)}
  end

  @spec active_window_layout(Layout.t(), map()) :: Layout.window_layout() | nil
  defp active_window_layout(%Layout{window_layouts: layouts}, %{
         workspace: %{windows: %{active: active}}
       }) do
    Map.get(layouts, active)
  end

  defp active_window_layout(_layout, _state), do: nil

  @spec active_window(map()) :: term() | nil
  defp active_window(%{workspace: %{windows: %{map: windows, active: active}}})
       when is_map(windows) do
    Map.get(windows, active)
  end

  defp active_window(_state), do: nil
end
