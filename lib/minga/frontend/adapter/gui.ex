defmodule Minga.Frontend.Adapter.GUI do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.AgentChatEncoder
  alias Minga.Frontend.Adapter.GUI.AgentContextEncoder
  alias Minga.Frontend.Adapter.GUI.BoardEncoder
  alias Minga.Frontend.Adapter.GUI.BottomPanelEncoder
  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ChangeSummaryEncoder
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.Frontend.Adapter.GUI.EditTimelineEncoder
  alias Minga.Frontend.Adapter.GUI.EncodedFrame
  alias Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoder
  alias Minga.Frontend.Adapter.GUI.ExtensionPanelEncoder
  alias Minga.Frontend.Adapter.GUI.FileTreeEncoder
  alias Minga.Frontend.Adapter.GUI.FloatPopupEncoder
  alias Minga.Frontend.Adapter.GUI.GitStatusEncoder
  alias Minga.Frontend.Adapter.GUI.GutterSeparatorEncoder
  alias Minga.Frontend.Adapter.GUI.HoverPopupEncoder
  alias Minga.Frontend.Adapter.GUI.MinibufferEncoder
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.Frontend.Adapter.GUI.NotificationsEncoder
  alias Minga.Frontend.Adapter.GUI.ObservatoryEncoder
  alias Minga.Frontend.Adapter.GUI.SearchStateEncoder
  alias Minga.Frontend.Adapter.GUI.SignatureHelpEncoder
  alias Minga.Frontend.Adapter.GUI.SidebarsEncoder
  alias Minga.Frontend.Adapter.GUI.SplitSeparatorsEncoder
  alias Minga.Frontend.Adapter.GUI.StatusBarEncoder
  alias Minga.Frontend.Adapter.GUI.TabBarEncoder
  alias Minga.Frontend.Adapter.GUI.ThemeEncoder
  alias Minga.Frontend.Adapter.GUI.WhichKeyEncoder
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.Frontend.Adapter.GUI.WorkspacesEncoder
  alias Minga.RenderModel

  # Ordered list of {field, encoder_module} pairs for component encoding.
  # Each encoder exposes encode/2 that returns {binary(), Caches.t()}.
  @component_encoders [
    {:theme, ThemeEncoder},
    {:breadcrumb, BreadcrumbEncoder},
    {:which_key, WhichKeyEncoder},
    {:notifications, NotificationsEncoder},
    {:search_state, SearchStateEncoder},
    {:git_status, GitStatusEncoder},
    {:agent_context, AgentContextEncoder},
    {:status_bar, StatusBarEncoder},
    {:observatory, ObservatoryEncoder},
    {:board, BoardEncoder},
    {:tab_bar, TabBarEncoder},
    {:workspaces, WorkspacesEncoder},
    {:sidebars, SidebarsEncoder},
    {:file_tree, FileTreeEncoder},
    {:picker, PickerEncoder},
    {:minibuffer, MinibufferEncoder},
    {:completion, CompletionEncoder},
    {:signature_help, SignatureHelpEncoder},
    {:agent_chat, AgentChatEncoder},
    {:bottom_panel, BottomPanelEncoder},
    {:change_summary, ChangeSummaryEncoder},
    {:edit_timeline, EditTimelineEncoder},
    {:extension_overlay, ExtensionOverlayEncoder},
    {:extension_panel, ExtensionPanelEncoder},
    {:hover_popup, HoverPopupEncoder},
    {:float_popup, FloatPopupEncoder}
  ]

  @metal_component_encoders [
    {:gutter_separator, GutterSeparatorEncoder},
    {:split_separators, SplitSeparatorsEncoder}
  ]

  @type window_metrics :: WindowEncoder.metrics()

  @doc "Encodes a full GUI render model into Metal-critical and SwiftUI chrome command groups."
  @spec encode(RenderModel.t(), Caches.t()) :: EncodedFrame.t()
  def encode(%RenderModel{} = model, %Caches{} = caches) do
    {window_content_cmds, caches, window_metrics} =
      encode_windows_with_metrics(model.windows, caches)

    {metal_ui_cmds, caches} = encode_metal_ui(model.ui, caches)
    {chrome_cmds, caches} = encode_ui(model.ui, caches)

    metal_commands = window_content_cmds ++ metal_ui_cmds

    metrics = %{
      window: window_metrics,
      metal_ui_bytes: IO.iodata_length(metal_ui_cmds),
      chrome_bytes: IO.iodata_length(chrome_cmds)
    }

    EncodedFrame.new(metal_commands, chrome_cmds, caches, metrics)
  end

  @spec encode_windows([RenderModel.Window.t()], Caches.t()) :: {[binary()], Caches.t()}
  def encode_windows(windows, %Caches{} = caches) when is_list(windows) do
    {cmds, caches, _metrics} = encode_windows_with_metrics(windows, caches)
    {cmds, caches}
  end

  @spec encode_windows_with_metrics([RenderModel.Window.t()], Caches.t()) ::
          {[binary()], Caches.t(), window_metrics()}
  def encode_windows_with_metrics(windows, %Caches{} = caches) when is_list(windows) do
    {cmds, caches, metrics} =
      windows
      |> Enum.filter(&buffer_window?/1)
      |> Enum.reduce({[], caches, empty_window_metrics()}, fn window,
                                                              {cmds_acc, caches_acc, metrics_acc} ->
        {cmds, caches, metrics} = encode_window_with_metrics(window, cmds_acc, caches_acc)
        {cmds, caches, merge_window_metrics(metrics_acc, metrics)}
      end)

    {Enum.reverse(cmds), caches, metrics}
  end

  @spec encode_metal_ui(RenderModel.UI.t(), Caches.t()) :: {[binary()], Caches.t()}
  def encode_metal_ui(%RenderModel.UI{} = ui, %Caches{} = caches) do
    encode_components(ui, @metal_component_encoders, caches)
  end

  @spec encode_ui(RenderModel.UI.t(), Caches.t()) :: {[binary()], Caches.t()}
  def encode_ui(%RenderModel.UI{} = ui, %Caches{} = caches) do
    encode_components(ui, @component_encoders, caches)
  end

  @spec encode_components(RenderModel.UI.t(), [{atom(), module()}], Caches.t()) ::
          {[binary()], Caches.t()}
  defp encode_components(%RenderModel.UI{} = ui, component_encoders, %Caches{} = caches) do
    {cmds, caches} =
      Enum.reduce(component_encoders, {[], caches}, fn {field, encoder}, {cmds_acc, caches_acc} ->
        encode_component(Map.get(ui, field), encoder, cmds_acc, caches_acc)
      end)

    {Enum.reverse(cmds), caches}
  end

  @spec buffer_window?(term()) :: boolean()
  defp buffer_window?(%RenderModel.Window{content_kind: :buffer}), do: true
  defp buffer_window?(_window), do: false

  @spec encode_window_with_metrics(RenderModel.Window.t(), [binary()], Caches.t()) ::
          {[binary()], Caches.t(), window_metrics()}
  defp encode_window_with_metrics(%RenderModel.Window{} = window, cmds, %Caches{} = caches) do
    fp = :erlang.phash2(window)
    {metadata, metadata_metrics} = WindowEncoder.encode_frame_metadata_with_metrics(window)

    if Map.get(caches.last_window_fps, window.window_id) == fp do
      {Enum.reverse(metadata) ++ cmds, caches, metadata_metrics}
    else
      {content, content_metrics} = WindowEncoder.encode_window_content_with_metrics(window)
      encoded = [content | metadata]
      caches = %{caches | last_window_fps: Map.put(caches.last_window_fps, window.window_id, fp)}

      {Enum.reverse(encoded) ++ cmds, caches,
       merge_window_metrics(content_metrics, metadata_metrics)}
    end
  end

  @spec empty_window_metrics() :: window_metrics()
  defp empty_window_metrics do
    %{row_bytes: 0, overlay_bytes: 0, gutter_bytes: 0, annotation_bytes: 0, metadata_bytes: 0}
  end

  @spec merge_window_metrics(window_metrics(), window_metrics()) :: window_metrics()
  defp merge_window_metrics(left, right) do
    %{
      row_bytes: left.row_bytes + right.row_bytes,
      overlay_bytes: left.overlay_bytes + right.overlay_bytes,
      gutter_bytes: left.gutter_bytes + right.gutter_bytes,
      annotation_bytes: left.annotation_bytes + right.annotation_bytes,
      metadata_bytes: left.metadata_bytes + right.metadata_bytes
    }
  end

  @spec encode_component(term(), module(), [binary()], Caches.t()) :: {[binary()], Caches.t()}
  defp encode_component(nil, _encoder, cmds, caches), do: {cmds, caches}

  defp encode_component(value, encoder, cmds, caches) do
    case encoder.encode(value, caches) do
      {nil, caches} -> {cmds, caches}
      {cmd, caches} -> {[cmd | cmds], caches}
    end
  end
end
