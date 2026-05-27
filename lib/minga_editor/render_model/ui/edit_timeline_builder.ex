defmodule MingaEditor.RenderModel.UI.EditTimelineBuilder do
  @moduledoc false

  alias Minga.Buffer
  alias Minga.RenderModel.UI.EditTimeline
  alias MingaEditor.Agent.EditTimeline, as: EditTimelineState
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @spec build(Context.t()) :: EditTimeline.t()
  def build(ctx) do
    timeline = get_timeline(ctx)
    path = active_buffer_path(ctx)

    if path != nil and timeline != nil and EditTimelineState.has_entries?(timeline, path) do
      build_visible(timeline, path)
    else
      build_hidden()
    end
  end

  @spec build_visible(EditTimelineState.t(), String.t()) :: EditTimeline.t()
  defp build_visible(timeline, path) do
    entries = EditTimelineState.entries_for(timeline, path)
    viewing = EditTimelineState.viewing_index(timeline, path)

    first_ts =
      case entries do
        [%{timestamp: ts} | _] -> ts
        _ -> 0
      end

    wire_entries =
      Enum.map(entries, fn entry ->
        %{
          index: entry.index,
          tool_name: entry.tool_name,
          timestamp_delta: abs(entry.timestamp - first_ts)
        }
      end)

    fp = :erlang.phash2({path, length(entries), viewing, Enum.map(entries, & &1.tool_name)})
    encoded = ProtocolGUI.encode_gui_edit_timeline(true, viewing, wire_entries)

    %EditTimeline{encoded: encoded, fingerprint: fp}
  end

  @spec build_hidden() :: EditTimeline.t()
  defp build_hidden do
    encoded = ProtocolGUI.encode_gui_edit_timeline(false, nil, [])

    %EditTimeline{encoded: encoded, fingerprint: :hidden}
  end

  @spec get_timeline(Context.t()) :: EditTimelineState.t() | nil
  defp get_timeline(%{agent_ui: %{view: %{edit_timeline: timeline}}}), do: timeline
  defp get_timeline(_ctx), do: nil

  @spec active_buffer_path(Context.t()) :: String.t() | nil
  defp active_buffer_path(%{buffers: %{active: buf}}) when is_pid(buf) do
    Buffer.file_path(buf)
  catch
    :exit, _ -> nil
  end

  defp active_buffer_path(_ctx), do: nil
end
