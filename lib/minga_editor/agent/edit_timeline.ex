defmodule MingaEditor.Agent.EditTimeline do
  @moduledoc """
  Per-file ordered sequence of agent edit snapshots.

  Records a snapshot after each tool-driven file change so the user can
  scrub through the agent's edit history. Each entry stores the file
  content *after* that edit, keyed by tool call ID.

  Baselines (the content before the first edit) are stored separately so
  the timeline can show the full range from "before agent touched the
  file" to the current state.
  """

  alias MingaEditor.Agent.DiffSnapshot

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
          baselines: %{String.t() => DiffSnapshot.t()},
          viewing: %{String.t() => non_neg_integer() | nil}
        }

  defstruct entries: %{},
            baselines: %{},
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
    timeline = maybe_record_baseline(timeline, path, before_content)

    existing = Map.get(timeline.entries, path, [])
    index = length(existing)

    entry = %Entry{
      index: index,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      timestamp: System.monotonic_time(:millisecond),
      snapshot: DiffSnapshot.from_content(after_content)
    }

    %{timeline | entries: Map.put(timeline.entries, path, existing ++ [entry])}
  end

  @spec entries_for(t(), String.t()) :: [Entry.t()]
  def entries_for(%__MODULE__{entries: entries}, path) do
    Map.get(entries, path, [])
  end

  @spec baseline_for(t(), String.t()) :: DiffSnapshot.t() | nil
  def baseline_for(%__MODULE__{baselines: baselines}, path) do
    Map.get(baselines, path)
  end

  @spec content_at(t(), String.t(), non_neg_integer()) :: {:ok, String.t()} | :error
  def content_at(%__MODULE__{} = timeline, path, index) do
    case Enum.find(entries_for(timeline, path), &(&1.index == index)) do
      nil -> :error
      entry -> {:ok, DiffSnapshot.content(entry.snapshot)}
    end
  end

  @spec baseline_content(t(), String.t()) :: {:ok, String.t()} | :error
  def baseline_content(%__MODULE__{baselines: baselines}, path) do
    case Map.get(baselines, path) do
      nil -> :error
      snapshot -> {:ok, DiffSnapshot.content(snapshot)}
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
        max_index = length(entries) - 1

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
            last_index = length(entries) - 1
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
    entries |> Map.get(path, []) |> length()
  end

  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{entries: entries, baselines: baselines}) do
    Enum.each(entries, fn {_path, path_entries} ->
      Enum.each(path_entries, fn %Entry{snapshot: snapshot} ->
        DiffSnapshot.cleanup(snapshot)
      end)
    end)

    Enum.each(baselines, fn {_path, snapshot} ->
      DiffSnapshot.cleanup(snapshot)
    end)

    :ok
  end

  defp maybe_record_baseline(%__MODULE__{baselines: baselines} = timeline, path, before_content) do
    if Map.has_key?(baselines, path) do
      timeline
    else
      %{timeline | baselines: Map.put(baselines, path, DiffSnapshot.from_content(before_content))}
    end
  end

  @spec set_viewing(t(), String.t(), non_neg_integer()) :: t()
  def set_viewing(%__MODULE__{} = timeline, path, index) do
    %{timeline | viewing: Map.put(timeline.viewing, path, index)}
  end
end
