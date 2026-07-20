defmodule MingaEditor.Layout.SurfaceRegistry do
  @moduledoc """
  Pure surface registry: the single source for "what is where on screen".

  Given the frame's editor state, `placements/1` returns an ordered list of
  `MingaEditor.Layout.SurfaceRegistry.Placement` entries, each carrying a
  `surface_id`, a `rect` (terminal cells, the existing `Layout.rect/0`
  convention), a `z` band, and a `hit_kind`. The list is ordered back-to-front
  by `z` (lowest first), so a stable sort by `z` reproduces paint order and a
  reverse walk reproduces hit-test precedence.

  This module is a calculation, not a process: state in, placements out. There
  is no ETS, no GenServer, no cache of its own. It is consumed where
  `MingaEditor.FocusTree`/`MingaEditor.Layout` are consumed today.

  ## The input rule (design of record, epic #2330)

  Clients resolve clicks on content they render and send semantic intents
  (`gui_actions`); the BEAM owns semantic stacking and conservative cell-grid
  containment for registry-placed surfaces. Native GUI frontends own final pixel
  placement for popups/widgets whose size depends on native measurement. That is
  the governing line for all surface input.

  A frontend hit-tests its own rendered content (a completion row, a
  notification action, an observatory node) and emits an intent like
  "item N clicked", exactly as SwiftUI's native hit-test already does. The BEAM
  does not re-derive what a click means on rendered content. What it owns is
  structure: which semantic surface wins when surfaces overlap (z-order
  arbitration, since stacking depends on editor state only the BEAM has), and
  conservative containment for BEAM-routed cell input so a click that misses
  every interactive element of a registry-placed surface is swallowed instead of
  falling through to the buffer underneath (`MingaEditor.Input.OverlaySink`).
  The picker is the one documented exception: it predates this rule and stays
  BEAM-resolved as shipped.

  ## One source, derived from the focus tree

  The registry is built by flattening the existing `MingaEditor.FocusTree`. The
  focus tree is the BEAM's authority for cell-grid mouse routing: it carries the
  per-frame `Layout` rects plus the single active overlay, with children stored
  in rendered z-order (back to front). By projecting that same tree into
  placement entries, the registry rect for every surface is, by construction,
  the same conservative cell rect the focus tree uses. Native GUI frontends may
  realize a different pixel rect for semantic popups after measuring native
  content.

  ## Scope honesty: single active overlay

  `FocusTree.add_modal_overlays/3` encodes the same exclusive precedence that
  Go's `overlayLines()` chain encodes today: at most one modal overlay (picker
  OR completion) is live per frame. The registry preserves that decision as
  data; it emits the single active overlay and nothing else. Multiple
  simultaneous overlays are newly *expressible* as a list but are deliberately
  NOT produced here. Enabling them is out of scope (see #2268, AC-4).

  Enumeration history (#2268 -> #2281). The Go compositor's `overlayLines()` chain
  once stacked surfaces that were not focus-tree nodes via a hand-ordered rank
  table. That table is now gone: every overlay surface is a focus-tree node with
  a BEAM-owned semantic z band and conservative cell rect.

  * **Cursor-anchored popups: hover popup, signature help.** Both are semantic
    popups whose BEAM rect is a conservative cell-grid containment/fallback rect
    (`HoverPopup.Presenter.box/3`/`SignatureHelp.Presenter.box/3`, driven by `FloatingWindow`).
    Native GUI frontends receive dedicated semantic opcodes and own final pixel
    placement. `FocusTree.add_floating_overlays/2` adds them as overlay nodes
    from `shell_state`; they occupy the `@z_floating_overlay` region (hover 290
    > signature help 280).

  * **Footer-band secondary overlays (#2281): float popup, agent context, tool
    manager, extension panel, observatory, edit timeline, notifications, extension
    overlay.** The owner ruled these mouse-driven (#2330), so the BEAM owns their
    semantic footer-band z and conservative cell containment. Native GUI
    frontends can still measure rich content inside those bands.
    `FocusTree.add_footer_band_overlays/3`
    adds each visible one (per `MingaEditor.Layout.FooterOverlays`) as an overlay
    node with a bottom-anchored full-width rect from `MingaEditor.Layout.OverlayBand`
    (porting the Go `maxOverlayHeight` clamp). They carry the exact historical
    stacking z (270/260/240/190/180/170/160/150), so Go composites the single
    highest-z winner by its placement rect instead of footer-appending. The
    single-active model still holds (#2268 AC-4): the tree may express several
    placements, but Go renders one. Their click events route to
    `MingaEditor.Input.OverlaySink`, which swallows mouse events so a click over a
    visible overlay never reaches the buffer underneath (AC-2). Per-surface
    activation semantics land as epic #2330 children.

  ## surface_id namespace and the identity-unification call (#2268)

  `surface_id/1` maps each focus-tree `content_type` to a stable atom in the
  registry's namespace; `surface_id_u16/1` maps that atom to its `u16` wire
  value and `hit_kind_u8/1` maps a `hit_kind` atom to its `u8` wire value. This
  module is the single source of both mappings.

  **Unification decision (#2268 proper):** the schema (`surface_placement` in
  `docs/protocol_schema.toml`, generated decoders on every frontend) carries
  `surface_id` as a raw `u16` and `hit_kind` as a raw `u8`. It deliberately does
  NOT add a `surface_id`/`hit_kind` enum: that would be a new schema vocabulary,
  and the consult's instruction was to keep the schema as the cross-language
  source of truth *without* a new vocabulary. The cross-language source of truth
  is therefore the wire shape plus the generated codec; the numeric identity of
  each surface stays authoritative here, and the emitter
  (`Minga.Frontend.Adapter.GUI.SurfaceLayoutEncoder`) *consumes* these functions
  rather than re-deriving numbers. One writer (this module), one reader (the
  encoder). `hit_kind_u8/1` reuses the window-encoder hit-kind numbering
  (`Minga.Frontend.Adapter.GUI.WindowEncoder` 1..6) and extends it with
  `:chrome` (7) and `:overlay` (8) so a placement's hit kind and a window hit
  region speak the same u8.

  ## hit_kind

  `hit_kind` reuses the window-scoped convention already encoded by
  `Minga.RenderModel.Window.HitRegion` and `Minga.Frontend.Adapter.GUI.WindowEncoder`
  (`:text`, `:gutter`, `:fold_control`, `:modeline`, `:status_bar`, `:divider`).
  Surface-level entries extend it with `:chrome` (structural chrome that routes
  to a handler but is not buffer text) and `:overlay` (a modal overlay surface).
  It is a coarse classification of what a click on the surface means, not a
  precise intra-surface region; intra-window hit regions stay with the window
  encoder.

  ## What is NOT unified here (documented per the epic)

  Several handlers compute a region's *interpretation* from math that is too
  entangled to swap behind a rect lookup without rewriting interaction
  semantics. For those, the registry is the source of the surface RECT, but the
  handler keeps its own interpretation:

  * `MingaEditor.Input.AgentMouse` splits the agent window content rect into a
    chat sub-column vs a preview sub-column using `chat_width_pct` math, and
    splits the prompt area off the bottom using `PromptRenderer` height math.
    The registry emits the agent window/panel rect; the chat/preview/prompt
    sub-division stays in `AgentMouse` (it is interaction semantics, not a
    placed surface). Forcing it into the registry would mean inventing
    sub-surfaces that nothing else places.
  * Tab-bar and modeline *segment* click regions
    (`tab_bar_click_regions`, `modeline_click_regions`) are authored at render
    time as text-property spans, not rects. The registry places the tab_bar and
    status_bar/modeline surfaces; the per-segment command lookup stays where it
    is.
  * Intra-window buffer geometry (gutter width, fold column, scroll position to
    buffer line) stays in `MingaEditor.Mouse.HitTest`. The registry places the
    window content rect; translating a cell to a buffer position is window
    interpretation, not surface placement.

  These are left intentionally. The registry's job in this slice is to be the
  one authority for surface *rects and z-order*, not to absorb every handler's
  interpretation of a click inside its surface.
  """

  alias MingaEditor.FocusTree
  alias MingaEditor.FocusTree.Node, as: TreeNode
  alias MingaEditor.Layout.SurfaceRegistry.Placement

  @typedoc "A surface identity in the registry's namespace."
  @type surface_id ::
          :tab_bar
          | :editor_area
          | :window
          | :buffer_content
          | :agent_chat_window
          | :agent_chat_content
          | :modeline
          | :file_tree
          | :sidebar
          | :custom_sidebar
          | :agent_panel
          | :status_bar
          | :minibuffer
          | :bottom_panel
          | :picker_backdrop
          | :picker
          | :completion_backdrop
          | :completion_menu
          | :hover_popup
          | :signature_help
          | :float_popup
          | :agent_context
          | :extension_panel
          | :observatory
          | :edit_timeline
          | :notifications
          | :extension_overlay

  @typedoc "Coarse classification of what a click on a surface means."
  @type hit_kind ::
          :text
          | :gutter
          | :fold_control
          | :modeline
          | :status_bar
          | :divider
          | :chrome
          | :overlay

  # ── z bands ─────────────────────────────────────────────────────────────────
  # Lower paints first (further back). Reverse order is hit-test precedence.
  # Bands leave gaps so future surfaces can slot between without renumbering the
  # whole stack. These mirror the back-to-front order FocusTree already builds:
  # base chrome and the editor area, then floating chrome (bottom panel), then
  # cursor-anchored floating popups (hover, signature help), then the single
  # active modal overlay on top.
  #
  # Band policy for the promoted floating popups (#2281): the historical Go
  # transitional chain placed hover (290) above signature help (280), and both
  # above the bottom panel (200) and below the modal overlay band (300). The
  # registry reproduces that exact order by slotting both popups in a
  # `@z_floating_overlay` region between the floating-chrome band (200) and the
  # overlay band (300), with hover one step above signature help. The numeric
  # gap to the overlay band stays explicit so a future surface can land between
  # the popups and the modal overlay without renumbering.

  @z_base_chrome 0
  @z_editor_area 100
  @z_floating_chrome 200
  @z_floating_overlay 280
  @z_overlay 300

  # Footer-band secondary overlays (#2281). These seven occupy the historical
  # transitional stacking the Go compositor encoded by hand. The owner ruled them
  # mouse-driven (#2330), so the BEAM now owns their geometry and z. The exact z
  # values are preserved from the Go transitional table so promotion is behaviour-
  # neutral: float popup highest, extension overlay lowest. Some sit above the
  # floating-chrome band (bottom panel, z=200) and some below it, exactly as the
  # old chain ordered them. The single-active model still holds; multiple visible
  # placements are expressible but Go renders only the highest-z winner.
  @z_float_popup 270
  @z_agent_context 260
  @z_extension_panel 190
  @z_observatory 180
  @z_edit_timeline 170
  @z_notifications 160
  @z_extension_overlay 150

  @doc """
  Returns the frame's surface placements ordered back-to-front by `z`.

  Pure: takes editor or render-pipeline state and returns a list of
  `Placement` structs. The list is the single source of surface rects and
  z-order for both compositing (sort by `z`) and hit-testing (reverse the
  sorted list).
  """
  @spec placements(map()) :: [Placement.t()]
  def placements(state) do
    state
    |> FocusTree.get()
    |> from_tree()
  end

  @typedoc """
  A placement projected to its wire shape: surface_id/hit_kind already mapped to
  their numeric identity, rect as a `{row, col, width, height}` cell map, z verbatim.
  """
  @type wire_placement :: %{
          surface_id: 0..65_535,
          rect: %{
            row: non_neg_integer(),
            col: non_neg_integer(),
            width: non_neg_integer(),
            height: non_neg_integer()
          },
          z: non_neg_integer(),
          hit_kind: 0..255
        }

  @doc """
  Returns the frame's placements projected to their wire shape.

  This is the boundary between the registry (which owns the surface/hit-kind
  numbering) and the wire encoder (which only lays out bytes). The encoder
  consumes these plain maps, so it never depends on `MingaEditor.*`: the registry
  stays the single authority for the numeric identity (#2268 unification call),
  and the emitter stays a pure byte layout over data. Order is preserved
  (back-to-front by z), so the wire list IS the compositing order.
  """
  @spec wire_placements(map()) :: [wire_placement()]
  def wire_placements(state) do
    state
    |> placements()
    |> Enum.map(&to_wire/1)
  end

  @spec to_wire(Placement.t()) :: wire_placement()
  defp to_wire(%Placement{
         surface_id: surface_id,
         rect: {row, col, width, height},
         z: z,
         hit_kind: hit_kind
       }) do
    %{
      surface_id: surface_id_u16(surface_id),
      rect: %{row: row, col: col, width: width, height: height},
      z: z,
      hit_kind: hit_kind_u8(hit_kind)
    }
  end

  @doc """
  Returns the rect of the first placed surface with `surface_id`, or `nil`.

  This is the read site hit-testers use to ask the registry "where is surface
  X?" instead of re-deriving the rect from `Layout` fields. Because placements
  are projected from the focus tree, this rect is the same one mouse routing
  hit-tests against. When several surfaces share an id (e.g. `:modeline` per
  window), the frontmost (highest `z`, last in paint order) is returned.
  """
  @spec rect_for(map(), surface_id()) :: MingaEditor.Layout.rect() | nil
  def rect_for(state, surface_id) do
    state
    |> placements()
    |> rect_for_in(surface_id)
  end

  @doc """
  Like `rect_for/2` but reads an already-computed placement list.
  """
  @spec rect_for_in([Placement.t()], surface_id()) :: MingaEditor.Layout.rect() | nil
  def rect_for_in(placements, surface_id) do
    placements
    |> Enum.filter(&(&1.surface_id == surface_id))
    |> Enum.max_by(& &1.z, fn -> nil end)
    |> case do
      nil -> nil
      %Placement{rect: rect} -> rect
    end
  end

  @doc """
  Returns true when `(row, col)` falls inside the placed surface `surface_id`.

  Half-open rect containment matching `FocusTree.Node.contains?/3`, so a
  registry-backed bounds check agrees with focus-tree hit-testing.
  """
  @spec within?(map(), surface_id(), integer(), integer()) :: boolean()
  def within?(state, surface_id, row, col) do
    case rect_for(state, surface_id) do
      nil -> false
      rect -> contains?(rect, row, col)
    end
  end

  @doc "Half-open rect containment: `row in [r, r+h)` and `col in [c, c+w)`."
  @spec contains?(MingaEditor.Layout.rect(), integer(), integer()) :: boolean()
  def contains?({r, c, w, h}, row, col) do
    row >= r and row < r + h and col >= c and col < c + w
  end

  @doc """
  Builds placements from an already-constructed focus tree.

  Exposed so callers that already hold the cached tree (mouse routing, render
  input) do not rebuild it. The tree's child order is rendered z-order; this
  walk assigns each node a `z` band and preserves back-to-front ordering.
  """
  @spec from_tree(FocusTree.t()) :: [Placement.t()]
  def from_tree(%TreeNode{} = root) do
    root
    |> collect()
    |> Enum.reverse()
    |> Enum.sort_by(& &1.z)
  end

  # Depth-first, back-to-front. Each placed node contributes one entry; the
  # viewport root itself is not a placed surface. Surface ids repeat
  # deliberately in split layouts: each window's buffer_content (and modeline)
  # is a real, independently placed surface with its own rect, and the future
  # emitter ships one placement per window. Consumers that want a single rect
  # for an id (rect_for_in/2) take the topmost by z.
  @spec collect(TreeNode.t()) :: [Placement.t()]
  defp collect(%TreeNode{content_type: :viewport, children: children}) do
    Enum.reduce(children, [], fn child, acc ->
      collect(child) ++ acc
    end)
  end

  defp collect(%TreeNode{} = node) do
    case placement_for(node) do
      nil ->
        collect_children(node)

      %Placement{} = placement ->
        [placement | collect_children(node)]
    end
  end

  @spec collect_children(TreeNode.t()) :: [Placement.t()]
  defp collect_children(%TreeNode{children: children}) do
    Enum.reduce(children, [], fn child, acc ->
      collect(child) ++ acc
    end)
  end

  @spec placement_for(TreeNode.t()) :: Placement.t() | nil
  defp placement_for(%TreeNode{content_type: content_type, rect: rect}) do
    case surface_id(content_type) do
      nil ->
        nil

      id ->
        Placement.new(id, rect, z_for(id), hit_kind_for(id))
    end
  end

  # ── surface_id namespace ────────────────────────────────────────────────────

  @doc """
  Maps a focus-tree `content_type` to a registry `surface_id`, or `nil` for
  content types that are not independently placed surfaces (the viewport root
  and the per-window `:window` container, whose content child is the placed
  surface).
  """
  @spec surface_id(TreeNode.content_type()) :: surface_id() | nil
  def surface_id(:viewport), do: nil
  def surface_id(:window), do: nil
  def surface_id(:agent_chat_window), do: nil
  def surface_id(:editor_area), do: :editor_area
  def surface_id(:tab_bar), do: :tab_bar
  def surface_id(:buffer_content), do: :buffer_content
  def surface_id(:agent_chat_content), do: :agent_chat_content
  def surface_id(:modeline), do: :modeline
  def surface_id(:file_tree), do: :file_tree
  def surface_id(:sidebar), do: :sidebar
  def surface_id(:agent_panel), do: :agent_panel
  def surface_id(:status_bar), do: :status_bar
  def surface_id(:minibuffer), do: :minibuffer
  def surface_id(:bottom_panel), do: :bottom_panel
  def surface_id(:picker_backdrop), do: :picker_backdrop
  def surface_id(:picker), do: :picker
  def surface_id(:completion_backdrop), do: :completion_backdrop
  def surface_id(:completion_menu), do: :completion_menu
  def surface_id(:hover_popup), do: :hover_popup
  def surface_id(:signature_help), do: :signature_help
  def surface_id(:float_popup), do: :float_popup
  def surface_id(:agent_context), do: :agent_context
  def surface_id(:extension_panel), do: :extension_panel
  def surface_id(:observatory), do: :observatory
  def surface_id(:edit_timeline), do: :edit_timeline
  def surface_id(:notifications), do: :notifications
  def surface_id(:extension_overlay), do: :extension_overlay
  def surface_id({:custom, :sidebar}), do: :custom_sidebar
  def surface_id({:custom, _other}), do: :custom_sidebar
  def surface_id(_other), do: nil

  @doc """
  Maps a registry `surface_id` atom to its `u16` wire value.

  Single BEAM-side source of the surface numbering. The schema carries
  `surface_id` as a raw `u16` (no enum, by decision: see the moduledoc), and
  `Minga.Frontend.Adapter.GUI.SurfaceLayoutEncoder` consumes this function
  rather than re-deriving numbers.
  """
  @spec surface_id_u16(surface_id()) :: 0..65_535
  def surface_id_u16(:editor_area), do: 1
  def surface_id_u16(:tab_bar), do: 2
  def surface_id_u16(:buffer_content), do: 3
  def surface_id_u16(:agent_chat_content), do: 4
  def surface_id_u16(:modeline), do: 5
  def surface_id_u16(:file_tree), do: 6
  def surface_id_u16(:sidebar), do: 7
  def surface_id_u16(:custom_sidebar), do: 8
  def surface_id_u16(:agent_panel), do: 9
  def surface_id_u16(:status_bar), do: 10
  def surface_id_u16(:minibuffer), do: 11
  def surface_id_u16(:bottom_panel), do: 12
  def surface_id_u16(:picker_backdrop), do: 13
  def surface_id_u16(:picker), do: 14
  def surface_id_u16(:completion_backdrop), do: 15
  def surface_id_u16(:completion_menu), do: 16
  def surface_id_u16(:hover_popup), do: 17
  def surface_id_u16(:signature_help), do: 18
  def surface_id_u16(:float_popup), do: 19
  def surface_id_u16(:agent_context), do: 20
  def surface_id_u16(:extension_panel), do: 22
  def surface_id_u16(:observatory), do: 23
  def surface_id_u16(:edit_timeline), do: 24
  def surface_id_u16(:notifications), do: 25
  def surface_id_u16(:extension_overlay), do: 26

  @doc """
  Maps a registry `hit_kind` atom to its `u8` wire value.

  Reuses the window-encoder hit-kind numbering
  (`Minga.Frontend.Adapter.GUI.WindowEncoder`: text 1, gutter 2, fold_control 3,
  modeline 4, divider 5, status_bar 6) so a placement's hit kind and a per-window
  hit region speak the same u8, and extends it with `:chrome` (7) and `:overlay`
  (8) for surface-level entries. Consumed by `SurfaceLayoutEncoder`.
  """
  @spec hit_kind_u8(hit_kind()) :: 0..255
  def hit_kind_u8(:text), do: 1
  def hit_kind_u8(:gutter), do: 2
  def hit_kind_u8(:fold_control), do: 3
  def hit_kind_u8(:modeline), do: 4
  def hit_kind_u8(:divider), do: 5
  def hit_kind_u8(:status_bar), do: 6
  def hit_kind_u8(:chrome), do: 7
  def hit_kind_u8(:overlay), do: 8

  # ── z assignment ────────────────────────────────────────────────────────────

  @spec z_for(surface_id()) :: non_neg_integer()
  defp z_for(:editor_area), do: @z_editor_area
  defp z_for(:buffer_content), do: @z_editor_area + 1
  defp z_for(:agent_chat_content), do: @z_editor_area + 1
  defp z_for(:modeline), do: @z_editor_area + 2
  defp z_for(:bottom_panel), do: @z_floating_chrome
  # Cursor-anchored floating popups, above floating chrome and below the modal
  # overlay band. hover (z=290) paints in front of signature help (z=280),
  # reproducing the historical Go transitional order exactly (#2281).
  defp z_for(:hover_popup), do: @z_floating_overlay + 10
  defp z_for(:signature_help), do: @z_floating_overlay
  # Footer-band secondary overlays (#2281): exact historical stacking z preserved
  # from the Go transitional table so promotion is behaviour-neutral.
  defp z_for(:float_popup), do: @z_float_popup
  defp z_for(:agent_context), do: @z_agent_context
  defp z_for(:extension_panel), do: @z_extension_panel
  defp z_for(:observatory), do: @z_observatory
  defp z_for(:edit_timeline), do: @z_edit_timeline
  defp z_for(:notifications), do: @z_notifications
  defp z_for(:extension_overlay), do: @z_extension_overlay
  defp z_for(id) when id in [:picker_backdrop, :completion_backdrop], do: @z_overlay
  defp z_for(id) when id in [:picker, :completion_menu], do: @z_overlay + 1
  defp z_for(_base_chrome), do: @z_base_chrome

  # ── hit_kind classification ─────────────────────────────────────────────────

  @spec hit_kind_for(surface_id()) :: hit_kind()
  defp hit_kind_for(:buffer_content), do: :text
  defp hit_kind_for(:agent_chat_content), do: :text
  defp hit_kind_for(:modeline), do: :modeline
  defp hit_kind_for(:status_bar), do: :status_bar
  defp hit_kind_for(id) when id in [:picker, :completion_menu], do: :overlay
  defp hit_kind_for(id) when id in [:picker_backdrop, :completion_backdrop], do: :overlay
  defp hit_kind_for(id) when id in [:hover_popup, :signature_help], do: :overlay

  defp hit_kind_for(id)
       when id in [
              :float_popup,
              :agent_context,
              :extension_panel,
              :observatory,
              :edit_timeline,
              :notifications,
              :extension_overlay
            ],
       do: :overlay

  defp hit_kind_for(_chrome), do: :chrome
end
