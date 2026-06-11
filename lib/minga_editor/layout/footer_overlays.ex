defmodule MingaEditor.Layout.FooterOverlays do
  @moduledoc """
  BEAM visibility source for the eight footer-band secondary overlays (#2281).

  These surfaces (float popup, agent context, tool manager, extension panel,
  observatory, edit timeline, notifications, extension overlay) historically had
  no BEAM rect: the Go compositor footer-appended one of them, sizing it
  frontend-side. The owner ruled them mouse-driven (#2330), so the BEAM now owns
  their footer-band geometry. This module is the single place that decides which
  of the eight is visible this frame and how tall its band is, reading the SAME
  underlying state the render-model builders read (so visibility never drifts
  from what the frontend actually renders).

  `visible/1` returns the visible footer overlays as `{surface_id, content_height}`
  pairs. `MingaEditor.FocusTree` turns each into an overlay node via
  `MingaEditor.Layout.OverlayBand.rect/2`; `MingaEditor.Layout.SurfaceRegistry`
  then places them with the historical stacking z. Only one overlay shows at a
  time in the fixed bottom band (single-active model, #2268 AC-4), and the band
  rect is bottom-anchored: its bottom edge sits directly above the minibuffer,
  exactly where the Go compositor used to footer-append the overlay.

  ## Content height and the residual phantom zone

  The rect must CONTAIN the rendered overlay (so a click over it is hit-tested and
  swallowed) but it should not span the whole band for a short overlay, or the
  rows below the content phantom-swallow clicks and the overlay renders well above
  the screen bottom. Two buckets:

    * **Count-derivable surfaces** (notifications, observatory, edit_timeline,
      extension_overlay): the BEAM knows the line count the Go renderer draws, so
      `content_height` is that count (clamped by the band ceiling, see the
      per-surface helpers below). The rect is sized to the content and the overlay
      hugs the screen bottom with no residual phantom zone (at most ~1 row of
      conservative slack: e.g. a notification item with no body draws 1 line where
      the count budgets 2).

    * **Wrap-dependent surfaces** (float_popup, extension_panel, and the dormant
      agent_context / tool_manager): these wrap text frontend-side where the BEAM
      only knows an item count, not a wrapped line count, so `content_height` stays
      `:max` (the clamp ceiling). Go bottom-aligns the rendered content within the
      band (`Y = rect.Row + bandHeight - contentLines`), so the overlay still hugs
      the screen bottom; the residual phantom zone (clamp ceiling minus rendered
      lines) sits ABOVE the content, between the buffer and the overlay, not below
      it. Per surface, the phantom band is at most `band_height - rendered_lines`
      rows tall: float_popup renders `1 + min(line_count, ceiling-1)` lines so its
      phantom zone is the remaining ceiling rows above; extension_panel renders a
      title plus up to two blocks per visible panel until it fills the band, so its
      phantom zone shrinks as panels are added; agent_context and tool_manager are
      dormant (never visible today) so their phantom zone is moot until a future
      child gives them a render-model source.

  ## Live vs dormant sources (honesty, #2281)

  Six surfaces have a live BEAM content source in the render-model path and so can
  actually become visible here: float popup, extension panel, observatory, edit
  timeline, notifications, extension overlay. Two are dormant on that path: the
  agent-context builder is a permanent `visible: false` stub
  (`MingaEditor.RenderModel.UI.AgentContextBuilder`, fed by `gui_payload/1` which
  the traditional shell always returns `nil` for), and the tool manager is not in
  the render-model UI at all (it ships only via the legacy `protocol/gui.ex`
  path). Their predicates here are wired to the same future sources, so they are
  placement-ready and will light up automatically when an epic child gives them a
  BEAM render-model source. Today their predicates never fire, which is correct:
  an overlay the BEAM never renders must not claim a footer band.
  """

  alias Minga.RenderModel.UI.AgentContext
  alias MingaEditor.RenderModel.UI.AgentContextBuilder

  @typedoc "A visible footer overlay: its registry surface id and its band content height."
  @type entry :: {surface_id :: atom(), content_height :: non_neg_integer() | :max}

  @doc """
  Returns the visible footer-band overlays for the frame, back-to-front by z.

  Each entry is `{surface_id, content_height}` where `surface_id` is a
  `MingaEditor.Layout.SurfaceRegistry` surface id and `content_height` is the
  BEAM-known content line count for the count-derivable surfaces (clamped by the
  band ceiling) or `:max` for the wrap-dependent ones (see the moduledoc).

  Order is ascending z (back-to-front): extension overlay (lowest z, painted
  first) up to float popup (highest z, painted last). This ordering matters for
  hit-testing: `FocusTree.add_footer_band_overlays/3` appends each entry as a
  child in list order, and `FocusTree`'s hit path reverses children so the
  LAST-appended (highest z) node wins among same-rect siblings. Returning
  ascending z here makes the BEAM hit-winner the highest-z node, the SAME surface
  Go composites on top (its highest-z render winner). If this returned descending
  z, the lowest-z node would win the reversed hit-test, inverting it against the
  render winner and breaking the per-surface handlers #2330 builds on top.
  """
  @spec visible(map()) :: [entry()]
  def visible(state) do
    [
      {:extension_overlay, extension_overlay_visible?(state),
       content_height_extension_overlay(state)},
      {:notifications, notifications_visible?(state), content_height_notifications(state)},
      {:edit_timeline, edit_timeline_visible?(state), content_height_edit_timeline(state)},
      {:observatory, observatory_visible?(state), content_height_observatory(state)},
      {:extension_panel, extension_panel_visible?(), :max},
      {:tool_manager, tool_manager_visible?(state), :max},
      {:agent_context, agent_context_visible?(state), :max},
      {:float_popup, float_popup_visible?(state), :max}
    ]
    |> Enum.filter(fn {_id, visible?, _height} -> visible? end)
    |> Enum.map(fn {id, _visible?, height} -> {id, height} end)
  end

  # ── Per-surface content height (count-derivable surfaces) ────────────────────
  #
  # These return the BEAM-known content line count so OverlayBand sizes the rect
  # to the content (clamped by the band ceiling) instead of the full band, so a
  # short overlay hugs the screen bottom instead of rendering rows above it. Each
  # count is verified against what the Go renderer actually draws (after its own
  # trailing-blank trim in overlayLayer):
  #
  #   * notifications  Go renders a 1-line title bar plus, per item, a header row
  #     (title + dismiss affordance) and a source/body row, plus one actions row
  #     for each item carrying inline actions (#2333). The count
  #     `1 + 2 * item_count + items_with_actions` is an exact-or-conservative
  #     upper bound on the trimmed Go output; undercounting here clips the
  #     actions row out of the band, making its click zones unreachable
  #     (OverlayBand clamps the whole thing by the band ceiling).
  #   * observatory / edit_timeline  Go renders charmTable: a 1-line header plus
  #     one line per row. The count `1 + row_count` matches the trimmed table.
  #   * extension_overlay  Go renders a 1-line title plus one line per entry. The
  #     count `1 + entry_count` matches the trimmed output.

  @spec content_height_notifications(map()) :: non_neg_integer()
  defp content_height_notifications(%{notifications: %{items: items}}) when is_list(items) do
    1 + 2 * length(items) + Enum.count(items, &notification_actions?/1)
  end

  defp content_height_notifications(_state), do: 1

  @spec notification_actions?(map() | struct()) :: boolean()
  defp notification_actions?(%{actions: [_ | _]}), do: true
  defp notification_actions?(_item), do: false

  @spec content_height_observatory(map()) :: non_neg_integer()
  defp content_height_observatory(%{shell_state: %{observatory_data: %{tree: tree}}}) do
    1 + length(Minga.SystemObserver.TreeNode.flatten(tree))
  end

  defp content_height_observatory(_state), do: 1

  @spec content_height_edit_timeline(map()) :: non_neg_integer()
  defp content_height_edit_timeline(state) do
    with timeline when timeline != nil <- edit_timeline_state(state),
         path when is_binary(path) <- active_buffer_path(state) do
      1 + length(MingaEditor.Agent.EditTimeline.entries_for(timeline, path))
    else
      _ -> 1
    end
  end

  @spec content_height_extension_overlay(map()) :: non_neg_integer()
  defp content_height_extension_overlay(_state) do
    1 + length(Minga.Extension.Overlay.all())
  end

  # ── Per-surface visibility, each reading the builder's underlying source ──────

  # Float popup: an observatory inspection float, or a window carrying a :float
  # popup rule. Mirrors MingaEditor.RenderModel.UI.FloatPopupBuilder.
  @spec float_popup_visible?(map()) :: boolean()
  defp float_popup_visible?(%{shell_state: %{observatory_inspection: %{visible: true}}}), do: true

  defp float_popup_visible?(%{workspace: %{windows: %{map: map}}}) when is_map(map) do
    Enum.any?(map, fn
      {_id,
       %{
         popup_meta: %MingaEditor.UI.Popup.Active{
           rule: %Minga.Popup.Rule{display: :float}
         }
       }} ->
        true

      _ ->
        false
    end)
  end

  defp float_popup_visible?(_state), do: false

  # Agent context: dormant on the render-model path (builder is a permanent stub,
  # see moduledoc). Driving it through the builder keeps the predicate honest and
  # ready to light up if a future child supplies a real gui_payload-backed model.
  @spec agent_context_visible?(map()) :: boolean()
  defp agent_context_visible?(_state) do
    case AgentContextBuilder.build(nil) do
      %AgentContext{visible: visible?} -> visible?
    end
  end

  # Tool manager: not in the render-model UI; no BEAM content source on this path.
  # Dormant until an epic child adds a render-model builder for it.
  @spec tool_manager_visible?(map()) :: boolean()
  defp tool_manager_visible?(_state), do: false

  # Extension panel: any visible extension or semantic panel.
  # Mirrors MingaEditor.RenderModel.UI.ExtensionPanelBuilder.
  @spec extension_panel_visible?() :: boolean()
  defp extension_panel_visible? do
    Minga.Extension.Panel.visible() != [] or
      MingaEditor.Agent.SemanticUI.Registry.panels() != []
  end

  # Observatory: the BEAM observatory panel is toggled on in shell_state.
  # Mirrors MingaEditor.RenderModel.UI.ObservatoryBuilder.
  @spec observatory_visible?(map()) :: boolean()
  defp observatory_visible?(%{shell_state: %{observatory_visible: true}}), do: true
  defp observatory_visible?(_state), do: false

  # Edit timeline: the active buffer has timeline entries.
  # Mirrors MingaEditor.RenderModel.UI.EditTimelineBuilder.
  @spec edit_timeline_visible?(map()) :: boolean()
  defp edit_timeline_visible?(state) do
    with timeline when timeline != nil <- edit_timeline_state(state),
         path when is_binary(path) <- active_buffer_path(state) do
      MingaEditor.Agent.EditTimeline.has_entries?(timeline, path)
    else
      _ -> false
    end
  end

  @spec edit_timeline_state(map()) :: term() | nil
  defp edit_timeline_state(%{workspace: %{agent_ui: %{view: %{edit_timeline: timeline}}}}),
    do: timeline

  defp edit_timeline_state(_state), do: nil

  @spec active_buffer_path(map()) :: String.t() | nil
  defp active_buffer_path(%{workspace: %{buffers: %{active: buf}}}) when is_pid(buf) do
    Minga.Buffer.file_path(buf)
  catch
    :exit, _ -> nil
  end

  defp active_buffer_path(_state), do: nil

  # Notifications: any active notification item.
  # Mirrors MingaEditor.RenderModel.UI.NotificationsBuilder (visible when items present).
  @spec notifications_visible?(map()) :: boolean()
  defp notifications_visible?(%{notifications: %{items: [_ | _]}}), do: true
  defp notifications_visible?(_state), do: false

  # Extension overlay: any registered extension inline overlay.
  # Mirrors MingaEditor.RenderModel.UI.ExtensionOverlayBuilder (entries present).
  @spec extension_overlay_visible?(map()) :: boolean()
  defp extension_overlay_visible?(_state) do
    Minga.Extension.Overlay.all() != []
  end
end
