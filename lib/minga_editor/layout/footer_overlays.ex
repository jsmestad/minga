defmodule MingaEditor.Layout.FooterOverlays do
  @moduledoc "BEAM visibility source for footer-band overlay placement."

  alias MingaEditor.RenderModel.UI.AgentContextBuilder
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Shell.Traditional.Observatory
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState

  @typedoc "A visible footer overlay: its registry surface id and its band content height."
  @type entry :: {surface_id :: atom(), content_height :: non_neg_integer() | :max}

  @doc "Returns visible footer-band overlays for the frame, back-to-front by z."
  @spec visible(map()) :: [entry()]
  def visible(state) do
    [
      {:extension_overlay, extension_overlay_visible?(state),
       content_height_extension_overlay(state)},
      {:notifications, notifications_visible?(state), content_height_notifications(state)},
      {:edit_timeline, edit_timeline_visible?(state), content_height_edit_timeline(state)},
      {:observatory, observatory_visible?(state), content_height_observatory(state)},
      {:extension_panel, extension_panel_visible?(), :max},
      {:agent_context, agent_context_visible?(state), :max},
      {:float_popup, float_popup_visible?(state), :max}
    ]
    |> Enum.filter(fn {_id, visible?, _height} -> visible? end)
    |> Enum.map(fn {id, _visible?, height} -> {id, height} end)
  end

  @spec content_height_notifications(map()) :: non_neg_integer()
  defp content_height_notifications(%Input{intent: %{frame: %{notifications: %{items: items}}}})
       when is_list(items) do
    1 + 2 * Enum.count(items) + Enum.count(items, &notification_actions?/1)
  end

  defp content_height_notifications(%{feedback: %{notifications: %{items: items}}})
       when is_list(items) do
    1 + 2 * Enum.count(items) + Enum.count(items, &notification_actions?/1)
  end

  defp content_height_notifications(_state), do: 1

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

  @spec content_height_edit_timeline(map()) :: non_neg_integer()
  defp content_height_edit_timeline(state) do
    case edit_timeline_state(state) do
      nil ->
        1

      timeline ->
        file_summaries = MingaEditor.Agent.EditTimeline.file_summaries(timeline)

        if file_summaries != [] do
          1 + Enum.count(file_summaries)
        else
          active_entries_count(state, timeline)
        end
    end
  end

  @spec content_height_extension_overlay(map()) :: non_neg_integer()
  defp content_height_extension_overlay(_state) do
    1 + Enum.count(Minga.Extension.Overlay.all())
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

  # Agent context: live BEAM-owned agent activity projection. The builder's
  # visibility predicate reads the same live editor state as the render model but
  # avoids building the full emit context, so this check stays cheap and non-recursive.
  @spec agent_context_visible?(map()) :: boolean()
  defp agent_context_visible?(state) do
    AgentContextBuilder.visible?(state)
  end

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

  # Edit timeline: the active buffer has timeline entries.
  # Mirrors MingaEditor.RenderModel.UI.EditTimelineBuilder.
  @spec edit_timeline_visible?(map()) :: boolean()
  defp edit_timeline_visible?(state) do
    case edit_timeline_state(state) do
      nil ->
        false

      timeline ->
        MingaEditor.Agent.EditTimeline.file_summaries(timeline) != [] or
          active_timeline_entries?(state, timeline)
    end
  end

  @spec active_entries_count(map(), term()) :: non_neg_integer()
  defp active_entries_count(state, timeline) do
    case active_buffer_path(state) do
      path when is_binary(path) ->
        1 + Enum.count(MingaEditor.Agent.EditTimeline.entries_for(timeline, path))

      _ ->
        1
    end
  end

  @spec active_timeline_entries?(map(), term()) :: boolean()
  defp active_timeline_entries?(state, timeline) do
    case active_buffer_path(state) do
      path when is_binary(path) -> MingaEditor.Agent.EditTimeline.has_entries?(timeline, path)
      _ -> false
    end
  end

  @spec edit_timeline_state(map()) :: term() | nil
  defp edit_timeline_state(%{workspace: %{agent_ui: %{view: %{edit_timeline: timeline}}}}),
    do: timeline

  defp edit_timeline_state(_state), do: nil

  defp active_buffer_path(%Input{workspace: %{buffers: %{active: buf}}}) when is_pid(buf) do
    Minga.Buffer.file_path(buf)
  catch
    :exit, _ -> nil
  end

  @spec active_buffer_path(map()) :: String.t() | nil
  defp active_buffer_path(%{workspace: %{buffers: %{active: buf}}}) when is_pid(buf) do
    Minga.Buffer.file_path(buf)
  catch
    :exit, _ -> nil
  end

  defp active_buffer_path(_state), do: nil

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
  defp extension_overlay_visible?(_state) do
    Minga.Extension.Overlay.all() != []
  end
end
