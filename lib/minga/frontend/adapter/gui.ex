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

  @spec encode_window_with_metrics(RenderModel.Window.t(), [binary()], Caches.t()) ::
          {[binary()], Caches.t(), window_metrics()}
  defp encode_window_with_metrics(%RenderModel.Window{} = window, cmds, %Caches{} = caches) do
    content_fp = window_content_fingerprint(window)
    overlay_fp = window_overlay_fingerprint(window)
    {metadata, metadata_metrics} = WindowEncoder.encode_frame_metadata_with_metrics(window)

    previous_content_fp = Map.get(caches.last_window_content_fps, window.window_id)
    previous_overlay_fp = Map.get(caches.last_window_overlay_fps, window.window_id)
    previous_content_epoch = Map.get(caches.last_window_content_epochs, window.window_id)
    previous_rows = Map.get(caches.last_window_rows, window.window_id, [])

    change = %{
      metadata: metadata,
      metadata_metrics: metadata_metrics,
      content_fp: content_fp,
      overlay_fp: overlay_fp,
      previous_content_fp: previous_content_fp,
      previous_overlay_fp: previous_overlay_fp,
      previous_content_epoch: previous_content_epoch,
      previous_rows: previous_rows,
      delta_pending?: Map.has_key?(caches.pending_window_content_delta_fps, window.window_id)
    }

    encode_window_change(window, cmds, caches, change)
  end

  @spec encode_window_change(RenderModel.Window.t(), [binary()], Caches.t(), map()) ::
          {[binary()], Caches.t(), window_metrics()}
  defp encode_window_change(
         %RenderModel.Window{} = window,
         cmds,
         %Caches{} = caches,
         %{delta_pending?: true} = change
       ) do
    encode_full_window_change(window, cmds, caches, change)
  end

  defp encode_window_change(
         %RenderModel.Window{} = window,
         cmds,
         %Caches{} = caches,
         %{
           content_fp: content_fp,
           previous_content_fp: previous_content_fp,
           previous_content_epoch: previous_content_epoch
         } = change
       )
       when previous_content_fp != content_fp and previous_content_epoch == window.content_epoch and
              not window.full_refresh do
    encode_delta_window_change(window, cmds, caches, change)
  end

  defp encode_window_change(
         %RenderModel.Window{} = window,
         cmds,
         %Caches{} = caches,
         %{content_fp: content_fp, previous_content_fp: previous_content_fp} = change
       )
       when previous_content_fp != content_fp do
    encode_full_window_change(window, cmds, caches, change)
  end

  defp encode_window_change(
         %RenderModel.Window{} = window,
         cmds,
         %Caches{} = caches,
         %{
           metadata: metadata,
           metadata_metrics: metadata_metrics,
           content_fp: content_fp,
           overlay_fp: overlay_fp,
           previous_overlay_fp: previous_overlay_fp
         }
       )
       when previous_overlay_fp != overlay_fp do
    delta = WindowEncoder.encode_overlay_delta(window)
    caches = put_window_fingerprints(caches, window.window_id, content_fp, overlay_fp)
    encoded = [delta | metadata]

    {Enum.reverse(encoded) ++ cmds, caches, add_overlay_delta_metrics(metadata_metrics, delta)}
  end

  defp encode_window_change(
         %RenderModel.Window{} = window,
         cmds,
         %Caches{} = caches,
         %{metadata: metadata, metadata_metrics: metadata_metrics}
       ) do
    delta = WindowEncoder.encode_overlay_delta(window)
    encoded = [delta | metadata]

    {Enum.reverse(encoded) ++ cmds, caches, add_overlay_delta_metrics(metadata_metrics, delta)}
  end

  @spec encode_full_window_change(RenderModel.Window.t(), [binary()], Caches.t(), map()) ::
          {[binary()], Caches.t(), window_metrics()}
  defp encode_full_window_change(
         %RenderModel.Window{} = window,
         cmds,
         %Caches{} = caches,
         %{
           metadata: metadata,
           metadata_metrics: metadata_metrics,
           content_fp: content_fp,
           overlay_fp: overlay_fp
         }
       ) do
    {content, content_metrics} = WindowEncoder.encode_window_content_with_metrics(window)
    encoded = [content | metadata]

    caches = put_window_fingerprints(caches, window.window_id, content_fp, overlay_fp, window)

    {Enum.reverse(encoded) ++ cmds, caches,
     merge_window_metrics(content_metrics, metadata_metrics)}
  end

  @spec encode_delta_window_change(RenderModel.Window.t(), [binary()], Caches.t(), map()) ::
          {[binary()], Caches.t(), window_metrics()}
  defp encode_delta_window_change(
         %RenderModel.Window{} = window,
         cmds,
         %Caches{} = caches,
         %{
           metadata: metadata,
           metadata_metrics: metadata_metrics,
           content_fp: content_fp,
           overlay_fp: overlay_fp,
           previous_rows: previous_rows
         }
       ) do
    encoder = delta_encoder(window, previous_rows)
    {delta, _has_refs?} = encoder.(window, previous_rows)
    encoded = [delta | metadata]

    caches = put_window_delta_pending(caches, window.window_id, content_fp, overlay_fp, window)
    metrics = add_rows_delta_metrics(metadata_metrics, delta)

    {Enum.reverse(encoded) ++ cmds, caches, metrics}
  end

  @spec delta_encoder(RenderModel.Window.t(), [RenderModel.Window.Row.t()]) ::
          (RenderModel.Window.t(), [RenderModel.Window.Row.t()] -> {binary(), boolean()})
  defp delta_encoder(%RenderModel.Window{} = window, previous_rows) do
    if viewport_delta?(window.rows, previous_rows) do
      &WindowEncoder.encode_viewport_delta/2
    else
      &WindowEncoder.encode_rows_delta/2
    end
  end

  @spec viewport_delta?([RenderModel.Window.Row.t()], [RenderModel.Window.Row.t()]) :: boolean()
  defp viewport_delta?(rows, previous_rows) do
    previous_hashes_by_id = Map.new(previous_rows, &{&1.row_id, &1.content_hash})

    Enum.all?(rows, fn row ->
      case Map.fetch(previous_hashes_by_id, row.row_id) do
        {:ok, hash} -> hash == row.content_hash
        :error -> true
      end
    end)
  end

  @spec put_window_fingerprints(Caches.t(), non_neg_integer(), integer(), integer()) :: Caches.t()
  defp put_window_fingerprints(%Caches{} = caches, window_id, content_fp, overlay_fp) do
    put_window_fingerprints(caches, window_id, content_fp, overlay_fp, nil)
  end

  @spec put_window_fingerprints(
          Caches.t(),
          non_neg_integer(),
          integer(),
          integer(),
          RenderModel.Window.t() | nil
        ) :: Caches.t()
  defp put_window_fingerprints(%Caches{} = caches, window_id, content_fp, overlay_fp, window) do
    caches = %{
      caches
      | last_window_fps: Map.put(caches.last_window_fps, window_id, content_fp),
        last_window_content_fps: Map.put(caches.last_window_content_fps, window_id, content_fp),
        last_window_overlay_fps: Map.put(caches.last_window_overlay_fps, window_id, overlay_fp),
        pending_window_content_delta_fps:
          Map.delete(caches.pending_window_content_delta_fps, window_id)
    }

    put_window_snapshot(caches, window_id, window)
  end

  @spec put_window_delta_pending(
          Caches.t(),
          non_neg_integer(),
          integer(),
          integer(),
          RenderModel.Window.t()
        ) :: Caches.t()
  defp put_window_delta_pending(%Caches{} = caches, window_id, content_fp, overlay_fp, window) do
    caches = put_window_fingerprints(caches, window_id, content_fp, overlay_fp, window)

    %{
      caches
      | pending_window_content_delta_fps:
          Map.put(caches.pending_window_content_delta_fps, window_id, content_fp)
    }
  end

  @spec put_window_snapshot(Caches.t(), non_neg_integer(), RenderModel.Window.t() | nil) ::
          Caches.t()
  defp put_window_snapshot(caches, _window_id, nil), do: caches

  defp put_window_snapshot(caches, window_id, %RenderModel.Window{} = window) do
    %{
      caches
      | last_window_content_epochs:
          Map.put(caches.last_window_content_epochs, window_id, window.content_epoch),
        last_window_rows: Map.put(caches.last_window_rows, window_id, window.rows)
    }
  end

  @spec window_content_fingerprint(RenderModel.Window.t()) :: integer()
  defp window_content_fingerprint(%RenderModel.Window{} = window) do
    :erlang.phash2({
      window.window_id,
      window.content_kind,
      window.rect,
      window.content_epoch,
      window.full_refresh,
      window.scroll_left,
      window.rows,
      window.selection,
      window.search_matches,
      window.diagnostic_ranges,
      window.document_highlights,
      window.annotations,
      window.geometry,
      window.gutter,
      window.indent_guides
    })
  end

  @spec window_overlay_fingerprint(RenderModel.Window.t()) :: integer()
  defp window_overlay_fingerprint(%RenderModel.Window{} = window) do
    :erlang.phash2({
      Map.get(window, :cursor_visible, true),
      window.cursor_row,
      window.cursor_col,
      window.cursor_shape,
      window.cursorline
    })
  end

  @spec empty_window_metrics() :: window_metrics()
  defp empty_window_metrics do
    %{row_bytes: 0, overlay_bytes: 0, gutter_bytes: 0, annotation_bytes: 0, metadata_bytes: 0}
  end

  @spec add_overlay_delta_metrics(window_metrics(), binary()) :: window_metrics()
  defp add_overlay_delta_metrics(metrics, delta) when is_binary(delta) do
    %{metrics | overlay_bytes: metrics.overlay_bytes + byte_size(delta)}
  end

  @spec add_rows_delta_metrics(window_metrics(), binary()) :: window_metrics()
  defp add_rows_delta_metrics(metrics, delta) when is_binary(delta) do
    %{metrics | row_bytes: metrics.row_bytes + byte_size(delta)}
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
