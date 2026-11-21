defmodule MingaEditor.Agent.EditTimeline do
  @moduledoc """
  Per-file ordered sequence of agent edit snapshots.

  Records a snapshot after each tool-driven file change so the user can
  scrub through the agent's edit history. Each entry stores the file
  content *after* that edit, keyed by tool call ID.

  Cumulative hunks are the per-path review authority. They represent the
  first pre-agent content to latest post-image without storing another full
  baseline copy.

  `generation` invalidates GUI targets when entries change or the timeline resets.
  Viewing and cumulative-review reprojection do not change entry identity.
  """

  alias MingaEditor.Agent.DiffSnapshot
  alias MingaEditor.Agent.FileChange
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

  @typedoc "Exact current post-image evidence for asynchronous review acquisition."
  @type postimage_digest :: <<_::256>>

  @type t :: %__MODULE__{
          generation: non_neg_integer(),
          entries: %{String.t() => [Entry.t()]},
          file_order: [String.t()],
          recovered_files: %{String.t() => pos_integer()},
          cumulative_hunks: %{
            String.t() => [Minga.Core.Diff.hunk()] | :discontinuous | :presence_change
          },
          postimage_digests: %{String.t() => postimage_digest()},
          viewing: %{String.t() => non_neg_integer() | nil}
        }

  @type review_status :: :pending | :counts_unavailable

  @type file_summary :: %{
          path: String.t(),
          entry_count: pos_integer(),
          lines_added: non_neg_integer(),
          lines_removed: non_neg_integer(),
          review_status: review_status()
        }

  defstruct generation: 0,
            entries: %{},
            file_order: [],
            recovered_files: %{},
            cumulative_hunks: %{},
            postimage_digests: %{},
            viewing: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record_edit(t(), FileChange.t()) :: t()
  def record_edit(%__MODULE__{} = timeline, %FileChange{
        path: path,
        before_content: before_content,
        after_content: after_content,
        tool_call_id: tool_call_id,
        tool_name: tool_name
      }) do
    hunks = edit_hunks(timeline, path, before_content, after_content)
    snapshot = if after_content == :absent, do: "", else: after_content
    existing = Map.get(timeline.entries, path, [])
    index = Enum.count(existing)

    entry = %Entry{
      index: index,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      timestamp: System.monotonic_time(:millisecond),
      snapshot: DiffSnapshot.from_content(snapshot)
    }

    file_order =
      case existing do
        [] -> timeline.file_order ++ [path]
        _entries -> timeline.file_order
      end

    %{
      timeline
      | entries: Map.put(timeline.entries, path, Enum.concat(existing, [entry])),
        file_order: file_order,
        generation: next_generation(),
        cumulative_hunks: Map.put(timeline.cumulative_hunks, path, hunks),
        postimage_digests:
          Map.put(timeline.postimage_digests, path, :crypto.hash(:sha256, snapshot))
    }
  end

  @spec edit_hunks(t(), String.t(), binary() | :absent, binary() | :absent) ::
          [Minga.Core.Diff.hunk()] | :discontinuous | :presence_change
  defp edit_hunks(_timeline, _path, :absent, _after_content), do: :presence_change
  defp edit_hunks(_timeline, _path, _before_content, :absent), do: :presence_change

  defp edit_hunks(timeline, path, before_content, after_content) do
    case Map.get(timeline.cumulative_hunks, path) do
      :presence_change ->
        :presence_change

      _ ->
        cumulative_edit(
          timeline,
          path,
          before_content,
          String.split(before_content, "\n"),
          String.split(after_content, "\n")
        )
    end
  end

  @doc "Reports when exact saved file presence is required to review a path."
  @spec presence_change?(t(), String.t()) :: boolean()
  def presence_change?(%__MODULE__{cumulative_hunks: hunks}, path),
    do: Map.get(hunks, path) == :presence_change

  @spec cumulative_edit(t(), String.t(), binary(), [String.t()], [String.t()]) ::
          [Minga.Core.Diff.hunk()] | :discontinuous
  defp cumulative_edit(timeline, path, before_content, before_lines, after_lines) do
    previous_digest = postimage_digest(timeline, path)

    case Map.get(timeline.cumulative_hunks, path) do
      :discontinuous ->
        :discontinuous

      _hunks ->
        if previous_digest == nil or previous_digest == :crypto.hash(:sha256, before_content) do
          timeline
          |> original_lines(path, before_lines)
          |> Git.diff_lines(after_lines)
          |> detach_hunk_old_lines()
        else
          :discontinuous
        end
    end
  end

  @spec reproject(t(), String.t(), [String.t()], [String.t()]) :: t()
  def reproject(%__MODULE__{} = timeline, path, original_lines, materialized_lines)
      when is_binary(path) and is_list(original_lines) and is_list(materialized_lines) do
    hunks = original_lines |> Git.diff_lines(materialized_lines) |> detach_hunk_old_lines()
    digest = :crypto.hash(:sha256, Enum.intersperse(materialized_lines, "\n"))

    %{
      timeline
      | cumulative_hunks: Map.put(timeline.cumulative_hunks, path, hunks),
        postimage_digests: Map.put(timeline.postimage_digests, path, digest)
    }
  end

  @spec entries_for(t(), String.t()) :: [Entry.t()]
  def entries_for(%__MODULE__{entries: entries}, path) do
    Map.get(entries, path, [])
  end

  @doc "Returns an opaque stable identity bound to the path, tool call, and entry index."
  @spec entry_id(String.t(), Entry.t()) :: String.t()
  def entry_id(path, %Entry{tool_call_id: tool_call_id, index: index}) when is_binary(path) do
    {path, tool_call_id, index}
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
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

  @doc "Installs recovered file membership without changing selection or live entries."
  @spec recover_files(t(), %{String.t() => pos_integer()}) :: t()
  def recover_files(%__MODULE__{recovered_files: files} = timeline, files), do: timeline

  def recover_files(%__MODULE__{} = timeline, files) do
    %{timeline | recovered_files: files, generation: next_generation()}
  end

  @doc "Checks whether a visible Changes file can be activated."
  @spec changed_file?(t(), String.t()) :: boolean()
  def changed_file?(%__MODULE__{} = timeline, path) do
    Map.has_key?(timeline.entries, path) or Map.has_key?(timeline.recovered_files, path)
  end

  @doc "Checks whether review must start from the saved task history."
  @spec recovered_file?(t(), String.t()) :: boolean()
  def recovered_file?(%__MODULE__{recovered_files: files}, path), do: Map.has_key?(files, path)

  @spec file_summaries(t()) :: [file_summary()]
  def file_summaries(%__MODULE__{} = timeline) do
    live =
      Enum.flat_map(timeline.file_order, fn path ->
        file_summary(timeline, {path, Map.fetch!(timeline.entries, path)})
      end)

    recovered =
      for {path, count} <- Enum.sort(timeline.recovered_files),
          not Map.has_key?(timeline.entries, path) do
        %{
          path: path,
          entry_count: count,
          lines_added: 0,
          lines_removed: 0,
          review_status: :counts_unavailable
        }
      end

    live ++ recovered
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = timeline) do
    cleanup_snapshots(timeline)
    %__MODULE__{generation: next_generation()}
  end

  @spec next_generation() :: pos_integer()
  defp next_generation,
    do: Integer.mod(System.unique_integer([:positive, :monotonic]), 4_294_967_295) + 1

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
    case Map.get(hunks, path) do
      hunks when is_list(hunks) -> hunks
      _unknown -> []
    end
  end

  @doc "Reports whether the attributed edits are separated by an unknown change."
  @spec discontinuous?(t(), String.t()) :: boolean()
  def discontinuous?(%__MODULE__{cumulative_hunks: hunks}, path),
    do: Map.get(hunks, path) == :discontinuous

  @doc "Returns the latest cumulative post-image fingerprint, including human reprojection."
  @spec postimage_digest(t(), String.t()) :: postimage_digest() | nil
  def postimage_digest(%__MODULE__{postimage_digests: digests}, path),
    do: Map.get(digests, path)

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

  @spec file_summary(t(), {String.t(), [Entry.t()]}) :: [file_summary()]
  defp file_summary(_timeline, {_path, []}), do: []

  defp file_summary(%__MODULE__{} = timeline, {path, entries}) do
    {added, removed} = diff_counts(cumulative_hunks(timeline, path))

    [
      %{
        path: path,
        entry_count: max(Enum.count(entries), Map.get(timeline.recovered_files, path, 0)),
        lines_added: added,
        lines_removed: removed,
        review_status:
          if(
            recovered_file?(timeline, path) or discontinuous?(timeline, path) or
              presence_change?(timeline, path),
            do: :counts_unavailable,
            else: :pending
          )
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

  @spec set_viewing(t(), String.t(), non_neg_integer()) :: t()
  def set_viewing(%__MODULE__{} = timeline, path, index) do
    %{timeline | viewing: Map.put(timeline.viewing, path, index)}
  end
end
