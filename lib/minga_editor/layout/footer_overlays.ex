defmodule MingaEditor.Layout.FooterOverlays do
  @moduledoc "BEAM visibility source for footer-band overlay placement."

  alias MingaEditor.RenderModel.UI.AgentContextBuilder
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Shell.Traditional.Observatory
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.ExtensionSurfaces
  alias MingaEditor.Window
  alias MingaEditor.Window.Content

  @typedoc "A visible footer overlay: its registry surface id and its band content height."
  @type entry :: {surface_id :: atom(), content_height :: non_neg_integer() | :max}

  @doc "Returns visible footer-band overlays for the frame, back-to-front by z."
  @spec visible(map()) :: [entry()]
  def visible(state) do
    [
      {:extension_overlay, extension_overlay_visible?(state),
       content_height_extension_overlay(state)},
      {:notifications, notifications_visible?(state), content_height_notifications(state)},
      {:observatory, observatory_visible?(state), content_height_observatory(state)},
      {:extension_panel, extension_panel_visible?(state), :max},
      {:agent_context, agent_context_visible?(state), :max},
      {:float_popup, float_popup_visible?(state), :max}
    ]
    |> Enum.filter(fn {_id, visible?, _height} -> visible? end)
    |> Enum.map(fn {id, _visible?, height} -> {id, height} end)
  end

  # The terminal frontend draws the notification center inside a rounded border
  # (#2617): one top and one bottom frame row around the content rows. The band
  # must contain the frame, or the bottom rows (each item's actions row and the
  # bottom border) fall outside the rect and the frontend crops them away.
  @notification_frame_rows 2

  @spec content_height_notifications(map()) :: non_neg_integer()
  defp content_height_notifications(%Input{intent: %{frame: %{notifications: %{items: items}}}})
       when is_list(items) do
    notification_rows(items)
  end

  defp content_height_notifications(%{feedback: %{notifications: %{items: items}}})
       when is_list(items) do
    notification_rows(items)
  end

  defp content_height_notifications(_state), do: 1 + @notification_frame_rows

  # Title bar, then a header and a body row per item, then an actions row for
  # each item with inline actions, all inside the frame.
  @spec notification_rows([map()]) :: non_neg_integer()
  defp notification_rows(items) do
    1 + 2 * Enum.count(items) + Enum.count(items, &notification_actions?/1) +
      @notification_frame_rows
  end

  @spec notification_actions?(map() | struct()) :: boolean()
  defp notification_actions?(%{actions: [_ | _]}), do: true
  defp notification_actions?(_item), do: false

  @spec content_height_observatory(map()) :: non_neg_integer()
  defp content_height_observatory(state) do
    case observatory(state) do
      %Observatory{} = observatory -> observatory_content_height(Observatory.data(observatory))
      nil -> 1
    end
  end

  @spec observatory_content_height(MingaEditor.Observatory.Data.t() | nil) :: non_neg_integer()
  defp observatory_content_height(%{tree: tree}),
    do: 1 + Enum.count(Minga.SystemObserver.TreeNode.flatten(tree))

  defp observatory_content_height(nil), do: 1

  @spec content_height_extension_overlay(map()) :: non_neg_integer()
  defp content_height_extension_overlay(state) do
    1 + Enum.count(Minga.Extension.Overlay.all(extension_overlay_registry(state)))
  end

  # ── Per-surface visibility, each reading the builder's underlying source ──────

  # Float popup: an observatory inspection float, or a window carrying a :float
  # popup rule. Mirrors MingaEditor.RenderModel.UI.FloatPopupBuilder.
  @spec float_popup_visible?(map()) :: boolean()
  defp float_popup_visible?(state) do
    observatory_inspection_visible?(observatory(state)) or float_window_visible?(state)
  end

  @spec observatory_inspection_visible?(Observatory.t() | nil) :: boolean()
  defp observatory_inspection_visible?(%Observatory{} = observatory),
    do: match?(%{visible: true}, Observatory.inspection(observatory))

  defp observatory_inspection_visible?(nil), do: false

  defp float_window_visible?(%Input{windows: %{map: map}}) when is_map(map) do
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

  @spec float_window_visible?(map()) :: boolean()
  defp float_window_visible?(%{workspace: %{windows: %{map: map}}}) when is_map(map) do
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

  defp float_window_visible?(_state), do: false

  # Native chrome still consumes the activity model.
  # The compact overlay only belongs over ordinary editors, never over Agent controls.
  @spec agent_context_visible?(map()) :: boolean()
  defp agent_context_visible?(%Input{windows: windows} = state) do
    agent_context_visible?(state, Map.get(windows.map, windows.active))
  end

  defp agent_context_visible?(%{workspace: %{windows: windows}} = state) do
    agent_context_visible?(state, Map.get(windows.map, windows.active))
  end

  @spec agent_context_visible?(map(), Window.t() | RenderWindow.t() | nil) :: boolean()
  defp agent_context_visible?(_state, %{content: {:subagent_peek, _}}), do: false

  defp agent_context_visible?(state, %{content: content}) do
    not Content.agent_body?(content) and AgentContextBuilder.visible?(state)
  end

  defp agent_context_visible?(state, nil), do: AgentContextBuilder.visible?(state)

  # Extension panel: any visible extension or semantic panel.
  # Mirrors MingaEditor.RenderModel.UI.ExtensionPanelBuilder.
  # The panels come from the registries this editor state names.
  # Another editor in the same VM (a concurrent test, for one) must not put a panel into this one's layout.
  @spec extension_panel_visible?(map()) :: boolean()
  defp extension_panel_visible?(state) do
    surfaces = ExtensionSurfaces.of(state)

    Minga.Extension.Panel.visible(surfaces.extension_panel_registry) != [] or
      MingaEditor.Agent.SemanticUI.Registry.panels(surfaces.agent_semantic_ui_registry) != []
  end

  # Observatory: the BEAM observatory panel is toggled on in shell_state.
  # Mirrors MingaEditor.RenderModel.UI.ObservatoryBuilder.
  @spec observatory_visible?(map()) :: boolean()
  defp observatory_visible?(state) do
    case observatory(state) do
      %Observatory{} = observatory -> Observatory.visible?(observatory)
      nil -> false
    end
  end

  defp observatory(%Input{intent: %{frame: %{shell_state: %TraditionalState{} = shell_state}}}),
    do: TraditionalState.observatory(shell_state)

  @spec observatory(map()) :: Observatory.t() | nil
  defp observatory(%MingaEditor.State{
         shell_runtime: %{state: %TraditionalState{} = shell_state}
       }),
       do: TraditionalState.observatory(shell_state)

  defp observatory(_state), do: nil

  defp notifications_visible?(%Input{intent: %{frame: %{notifications: %{items: [_ | _]}}}}),
    do: true

  # Notifications: any active notification item.
  # Mirrors MingaEditor.RenderModel.UI.NotificationsBuilder (visible when items present).
  @spec notifications_visible?(map()) :: boolean()
  defp notifications_visible?(%MingaEditor.State{feedback: %{notifications: %{items: [_ | _]}}}),
    do: true

  defp notifications_visible?(_state), do: false

  # Extension overlay: any registered extension inline overlay.
  # Mirrors MingaEditor.RenderModel.UI.ExtensionOverlayBuilder (entries present).
  @spec extension_overlay_visible?(map()) :: boolean()
  defp extension_overlay_visible?(state) do
    Minga.Extension.Overlay.all(extension_overlay_registry(state)) != []
  end

  @spec extension_overlay_registry(map()) :: Minga.Extension.Overlay.table()
  defp extension_overlay_registry(state),
    do: ExtensionSurfaces.of(state).extension_overlay_registry
end
