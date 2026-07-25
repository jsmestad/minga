defmodule MingaEditor.RenderModel.UI.EditTimelineBuilder do
  @moduledoc false

  alias Minga.Buffer
  alias Minga.RenderModel.UI.EditTimeline
  alias MingaEditor.Agent.EditTimeline, as: EditTimelineState
  alias MingaEditor.Frontend.Emit.Context

  @spec build(Context.t()) :: EditTimeline.t()
  def build(ctx) do
    timeline = get_timeline(ctx)
    path = active_buffer_path(ctx)

    if timeline != nil and visible?(timeline, path) do
      build_visible(timeline, path)
    else
      build_hidden()
    end
  end

  @spec build_visible(EditTimelineState.t(), String.t() | nil) :: EditTimeline.t()
  defp build_visible(timeline, path) do
    entries = active_entries(timeline, path)
    viewing = active_viewing_index(timeline, path)

    first_ts =
      case entries do
        [%{timestamp: ts} | _] -> ts
        _ -> 0
      end

    timeline_entries =
      Enum.map(entries, fn entry ->
        %EditTimeline.Entry{
          index: entry.index,
          tool_name: entry.tool_name,
          timestamp_delta: abs(entry.timestamp - first_ts)
        }
      end)

    %EditTimeline{
      visible?: true,
      viewing_index: viewing,
      entries: timeline_entries,
      files: file_entries(timeline, path)
    }
  end

  @spec build_hidden() :: EditTimeline.t()
  defp build_hidden do
    %EditTimeline{visible?: false}
  end

  @spec get_timeline(Context.t()) :: EditTimelineState.t() | nil
  defp get_timeline(%Context{workspace: %{agent_ui: %{view: %{edit_timeline: timeline}}}}),
    do: timeline

  defp get_timeline(_ctx), do: nil

  @spec active_buffer_path(Context.t()) :: String.t() | nil
  defp active_buffer_path(%Context{workspace: %{buffers: %{active: buf}}}) when is_pid(buf) do
    Buffer.file_path(buf)
  catch
    :exit, _ -> nil
  end

  defp active_buffer_path(_ctx), do: nil

  @spec visible?(EditTimelineState.t(), String.t() | nil) :: boolean()
  defp visible?(timeline, path) do
    EditTimelineState.file_summaries(timeline) != [] or
      (path != nil and EditTimelineState.has_entries?(timeline, path))
  end

  @spec active_entries(EditTimelineState.t(), String.t() | nil) :: [EditTimelineState.Entry.t()]
  defp active_entries(_timeline, nil), do: []
  defp active_entries(timeline, path), do: EditTimelineState.entries_for(timeline, path)

  @spec active_viewing_index(EditTimelineState.t(), String.t() | nil) :: non_neg_integer() | nil
  defp active_viewing_index(_timeline, nil), do: nil
  defp active_viewing_index(timeline, path), do: EditTimelineState.viewing_index(timeline, path)

  @spec file_entries(EditTimelineState.t(), String.t() | nil) :: [EditTimeline.FileEntry.t()]
  defp file_entries(timeline, active_path) do
    timeline
    |> EditTimelineState.file_summaries()
    |> Enum.map(&file_entry(&1, active_path))
  end

  @spec file_entry(EditTimelineState.file_summary(), String.t() | nil) ::
          EditTimeline.FileEntry.t()
  defp file_entry(summary, active_path) do
    %EditTimeline.FileEntry{
      path: summary.path,
      entry_count: summary.entry_count,
      lines_added: summary.lines_added,
      lines_removed: summary.lines_removed,
      review_status: file_review_status(summary, active_path)
    }
  end

  @spec file_review_status(EditTimelineState.file_summary(), String.t() | nil) ::
          EditTimeline.FileEntry.review_status()
  defp file_review_status(%{path: path}, path), do: :reviewing
  defp file_review_status(%{review_status: status}, _active_path), do: status
end
