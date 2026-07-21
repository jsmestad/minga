defmodule MingaEditor.Agent.EditTimeline do
  @moduledoc """
  Per-file ordered sequence of agent edit snapshots.

  Records a snapshot after each tool-driven file change so the user can
  scrub through the agent's edit history. Each entry stores the file
  content *after* that edit, keyed by tool call ID.

  Cumulative hunks are the per-path review authority. They represent the
  first pre-agent content to latest post-image without storing another full
  baseline copy.
  """

  alias MingaEditor.Agent.DiffSnapshot
  alias Minga.Git

  defmodule Entry do
    @moduledoc false

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            tool_call_id: String.t(),
            tool_name: String.t(),
            timestamp: integer(),
            snapshot: DiffSnapshot.t()
          }

    @enforce_keys [:index, :tool_call_id, :tool_name, :timestamp, :snapshot]
    defstruct [:index, :tool_call_id, :tool_name, :timestamp, :snapshot]
  end

  @type t :: %__MODULE__{
          entries: %{String.t() => [Entry.t()]},
          cumulative_hunks: %{String.t() => [Minga.Core.Diff.hunk()]},
          viewing: %{String.t() => non_neg_integer() | nil}
        }

  @type review_status :: :pending | :reviewing

  @type file_summary :: %{
          path: String.t(),
          entry_count: pos_integer(),
          lines_added: non_neg_integer(),
          lines_removed: non_neg_integer(),
          review_status: review_status()
        }

  defstruct entries: %{},
            cumulative_hunks: %{},
            viewing: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record_edit(t(), String.t(), String.t(), String.t(), String.t(), String.t()) :: t()
  def record_edit(
        %__MODULE__{} = timeline,
        path,
        tool_call_id,
        tool_name,
        before_content,
        after_content
      ) do
    before_lines = String.split(before_content, "\n")
    after_lines = String.split(after_content, "\n")

    hunks =
      original_lines(timeline, path, before_lines)
      |> Git.diff_lines(after_lines)
      |> detach_hunk_old_lines()

    existing = Map.get(timeline.entries, path, [])
    index = Enum.count(existing)

    entry = %Entry{
      index: index,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      timestamp: System.monotonic_time(:millisecond),
      snapshot: DiffSnapshot.from_content(after_content)
    }

    %{
      timeline
      | entries: Map.put(timeline.entries, path, Enum.concat(existing, [entry])),
        cumulative_hunks: Map.put(timeline.cumulative_hunks, path, hunks)
    }
  end

  @spec reproject(t(), String.t(), [String.t()], [String.t()]) :: t()
  def reproject(%__MODULE__{} = timeline, path, original_lines, materialized_lines)
      when is_binary(path) and is_list(original_lines) and is_list(materialized_lines) do
    hunks = original_lines |> Git.diff_lines(materialized_lines) |> detach_hunk_old_lines()
    %{timeline | cumulative_hunks: Map.put(timeline.cumulative_hunks, path, hunks)}
  end

  @spec entries_for(t(), String.t()) :: [Entry.t()]
  def entries_for(%__MODULE__{entries: entries}, path) do
    Map.get(entries, path, [])
  end

  @spec content_at(t(), String.t(), non_neg_integer()) :: {:ok, String.t()} | :error
  def content_at(%__MODULE__{} = timeline, path, index) do
    case Enum.find(entries_for(timeline, path), &(&1.index == index)) do
      nil -> :error
      entry -> {:ok, DiffSnapshot.content(entry.snapshot)}
    end
  end

  @spec viewing_index(t(), String.t()) :: non_neg_integer() | nil
  def viewing_index(%__MODULE__{viewing: viewing}, path) do
    Map.get(viewing, path)
  end

  @spec navigate_next(t(), String.t()) :: {t(), :moved | :at_end | :no_entries}
  def navigate_next(%__MODULE__{} = timeline, path) do
    entries = entries_for(timeline, path)

    case entries do
      [] ->
        {timeline, :no_entries}

      _ ->
        current = viewing_index(timeline, path)
        max_index = Enum.count(entries) - 1

        case current do
          nil -> {timeline, :at_end}
          i when i >= max_index -> {go_live(timeline, path), :at_end}
          i -> {set_viewing(timeline, path, i + 1), :moved}
        end
    end
  end

  @spec navigate_prev(t(), String.t()) :: {t(), :moved | :at_baseline | :no_entries}
  def navigate_prev(%__MODULE__{} = timeline, path) do
    entries = entries_for(timeline, path)

    case entries do
      [] ->
        {timeline, :no_entries}

      _ ->
        current = viewing_index(timeline, path)

        case current do
          nil ->
            last_index = Enum.count(entries) - 1
            {set_viewing(timeline, path, last_index), :moved}

          0 ->
            {timeline, :at_baseline}

          i ->
            {set_viewing(timeline, path, i - 1), :moved}
        end
    end
  end

  @spec go_live(t(), String.t()) :: t()
  def go_live(%__MODULE__{} = timeline, path) do
    %{timeline | viewing: Map.delete(timeline.viewing, path)}
  end

  @spec has_entries?(t(), String.t()) :: boolean()
  def has_entries?(%__MODULE__{entries: entries}, path) do
    case Map.get(entries, path) do
      nil -> false
      [] -> false
      _ -> true
    end
  end

  @spec entry_count(t(), String.t()) :: non_neg_integer()
  def entry_count(%__MODULE__{entries: entries}, path) do
    entries |> Map.get(path, []) |> Enum.count()
  end

  @spec file_summaries(t()) :: [file_summary()]
  def file_summaries(%__MODULE__{entries: entries} = timeline) do
    entries
    |> non_empty_file_entries()
    |> file_summaries_for_entries(timeline)
    |> Enum.sort_by(& &1.path)
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = timeline) do
    cleanup_snapshots(timeline)
    new()
  end

  @spec cleanup_snapshots(t()) :: :ok
  defp cleanup_snapshots(%__MODULE__{entries: entries}) do
    Enum.each(entries, fn {_path, path_entries} ->
      Enum.each(path_entries, fn %Entry{snapshot: snapshot} ->
        DiffSnapshot.cleanup(snapshot)
      end)
    end)

    :ok
  end

  @spec cumulative_hunks(t(), String.t()) :: [Minga.Core.Diff.hunk()]
  def cumulative_hunks(%__MODULE__{cumulative_hunks: hunks}, path) do
    Map.get(hunks, path, [])
  end

  @spec original_lines(t(), String.t(), [String.t()]) :: [String.t()]
  defp original_lines(%__MODULE__{} = timeline, path, before_lines) do
    timeline
    |> cumulative_hunks(path)
    |> Enum.reverse()
    |> Enum.reduce(before_lines, &Git.revert_hunk(&2, &1))
  end

  @spec detach_hunk_old_lines([Minga.Core.Diff.hunk()]) :: [Minga.Core.Diff.hunk()]
  defp detach_hunk_old_lines(hunks) do
    Enum.map(hunks, fn hunk ->
      %{hunk | old_lines: Enum.map(hunk.old_lines, &detach_binary/1)}
    end)
  end

  @spec detach_binary(String.t()) :: String.t()
  defp detach_binary(line) do
    if byte_size(line) < :binary.referenced_byte_size(line), do: :binary.copy(line), else: line
  end

  @spec non_empty_file_entries(%{String.t() => [Entry.t()]}) :: [{String.t(), [Entry.t()]}]
  defp non_empty_file_entries(entries) do
    Enum.reject(entries, fn {_path, path_entries} -> path_entries == [] end)
  end

  @spec file_summaries_for_entries([{String.t(), [Entry.t()]}], t()) :: [file_summary()]
  defp file_summaries_for_entries([_single_file], _timeline), do: []

  defp file_summaries_for_entries(file_entries, timeline) do
    Enum.flat_map(file_entries, &file_summary(timeline, &1))
  end

  @spec file_summary(t(), {String.t(), [Entry.t()]}) :: [file_summary()]
  defp file_summary(_timeline, {_path, []}), do: []

  defp file_summary(%__MODULE__{} = timeline, {path, entries}) do
    {added, removed} = diff_counts(cumulative_hunks(timeline, path))

    [
      %{
        path: path,
        entry_count: Enum.count(entries),
        lines_added: added,
        lines_removed: removed,
        review_status: review_status(timeline, path)
      }
    ]
  end

  @spec diff_counts([Minga.Core.Diff.hunk()]) :: {non_neg_integer(), non_neg_integer()}
  defp diff_counts(hunks), do: Enum.reduce(hunks, {0, 0}, &add_hunk_counts/2)

  @spec add_hunk_counts(Minga.Core.Diff.hunk(), {non_neg_integer(), non_neg_integer()}) ::
          {non_neg_integer(), non_neg_integer()}
  defp add_hunk_counts(%{type: :added, count: count}, {added, removed}) do
    {added + count, removed}
  end

  defp add_hunk_counts(%{type: :deleted, old_count: old_count}, {added, removed}) do
    {added, removed + old_count}
  end

  defp add_hunk_counts(%{type: :modified, count: count, old_count: old_count}, {added, removed}) do
    {added + count, removed + old_count}
  end

  @spec review_status(t(), String.t()) :: review_status()
  defp review_status(%__MODULE__{} = timeline, path) do
    case viewing_index(timeline, path) do
      nil -> :pending
      _index -> :reviewing
    end
  end

  @spec set_viewing(t(), String.t(), non_neg_integer()) :: t()
  def set_viewing(%__MODULE__{} = timeline, path, index) do
    %{timeline | viewing: Map.put(timeline.viewing, path, index)}
  end
end
