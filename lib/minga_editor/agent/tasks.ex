defmodule MingaEditor.Agent.Tasks do
  @moduledoc """
  Every task Minga is working on, as the editor sees it: one place for the tasks drawer, the modeline's needs-you count and notifications.

  A task is an agent session the editor follows, whichever workspace or tab shows it. The editor feeds every session event through `observe/4`, before it routes the event to the active conversation or a background tab, so a background task's approval is kept here instead of being dropped. Each session remains the authority: an approval answered anywhere is cleared here by the session's `{:approval_resolved, ...}` event, and a late answer is refused by the session.

  Pure: callers pass wall-clock times, and the owning workflow does all process work.
  """

  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.Tasks.Entry
  alias MingaEditor.Agent.Tasks.Subagent

  @typedoc "A row of the task tree: a task, or a foreground subagent beneath one."
  @type node_t :: %{
          required(:item) => Entry.t() | Subagent.t(),
          required(:depth) => non_neg_integer(),
          required(:parent) => pid() | nil
        }

  @type t :: %__MODULE__{
          entries: %{pid() => Entry.t()},
          next_seq: non_neg_integer()
        }

  defstruct entries: %{}, next_seq: 0

  # Rows are ordered needs-you first, then by how soon each state wants a look.
  @state_rank %{
    needs_you: 0,
    working: 1,
    waiting: 2,
    failed: 3,
    done: 4,
    stopped: 5,
    nil: 6
  }

  @doc "No tasks."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Starts following a session, or updates what is known about one already followed.

  Options: `:title` (the task's goal; a task keeps its first goal) and `:parent` (the task that started it, for a background subagent).
  """
  @spec follow(t(), pid(), integer(), keyword()) :: t()
  def follow(%__MODULE__{} = tasks, pid, now, opts \\ []) when is_pid(pid) do
    {tasks, entry} = ensure(tasks, pid, now)

    entry =
      entry
      |> maybe(Keyword.get(opts, :title), &Entry.name/2)
      |> maybe(Keyword.get(opts, :parent), &Entry.adopt/2)

    put(tasks, entry)
  end

  @doc """
  Applies one session event.

  A session the editor subscribes to says so first (`{:credentials_status, _}` and `{:connection_changed, _}` are sent to every new subscriber), and that starts following it. Any other event from a session not followed is ignored, so a late event from a session that already stopped, or from a dismissed inline session, cannot bring a task back.
  """
  @spec observe(t(), pid(), term(), integer()) :: t()
  def observe(%__MODULE__{entries: entries} = tasks, pid, event, now) when is_pid(pid) do
    case Map.fetch(entries, pid) do
      {:ok, entry} -> put(tasks, Entry.observe(entry, event, now))
      :error -> observe_unfollowed(tasks, pid, event, now)
    end
  end

  @spec observe_unfollowed(t(), pid(), term(), integer()) :: t()
  defp observe_unfollowed(tasks, pid, {kind, _detail} = event, now)
       when kind in [:credentials_status, :connection_changed] do
    {tasks, entry} = ensure(tasks, pid, now)
    put(tasks, Entry.observe(entry, event, now))
  end

  defp observe_unfollowed(tasks, _pid, _event, _now), do: tasks

  @doc "Names a followed task by its goal, when it has none yet."
  @spec name(t(), pid(), String.t()) :: t()
  def name(%__MODULE__{} = tasks, pid, title),
    do: update_entry(tasks, pid, &Entry.name(&1, title))

  @doc "Carries a task over to the session that replaced its crashed one, at wall-clock time `now`."
  @spec replace(t(), pid(), pid(), integer()) :: t()
  def replace(%__MODULE__{entries: entries} = tasks, old, new, now)
      when is_pid(old) and is_pid(new) do
    case Map.pop(entries, old) do
      {nil, _entries} ->
        tasks

      {entry, entries} ->
        entries =
          entries
          |> Map.put(new, Entry.restart(entry, new, now))
          |> Map.new(fn {pid, child} -> {pid, Entry.reparent(child, old, new)} end)

        %{tasks | entries: entries}
    end
  end

  @doc "Stops following a session that ended."
  @spec forget(t(), pid()) :: t()
  def forget(%__MODULE__{entries: entries} = tasks, pid),
    do: %{tasks | entries: Map.delete(entries, pid)}

  @doc "Stops following every session on a node that disconnected; its sessions report nothing more."
  @spec forget_node(t(), node()) :: t()
  def forget_node(%__MODULE__{entries: entries} = tasks, node) when is_atom(node),
    do: %{tasks | entries: Map.reject(entries, fn {pid, _entry} -> node(pid) == node end)}

  @doc "Clears a task's approval once its session accepted an answer, or said none is pending."
  @spec resolve_approval(t(), pid(), MingaAgent.ToolApproval.Target.t()) :: t()
  def resolve_approval(%__MODULE__{} = tasks, pid, target),
    do: update_entry(tasks, pid, &Entry.resolve_approval(&1, target))

  @doc "The task a session belongs to."
  @spec fetch(t(), pid()) :: {:ok, Entry.t()} | :error
  def fetch(%__MODULE__{entries: entries}, pid), do: Map.fetch(entries, pid)

  @doc "The approval a task is waiting on, bound to its session."
  @spec approval(t(), pid()) :: PendingApproval.t() | nil
  def approval(%__MODULE__{entries: entries}, pid) do
    case Map.fetch(entries, pid) do
      {:ok, %Entry{approval: approval}} -> approval
      :error -> nil
    end
  end

  @doc "How many tasks need you."
  @spec needs_you_count(t()) :: non_neg_integer()
  def needs_you_count(%__MODULE__{entries: entries}),
    do: Enum.count(entries, fn {_pid, entry} -> Entry.state(entry) == :needs_you end)

  @doc "How many tasks and subagents show each state, for the drawer header."
  @spec counts(t()) :: %{Entry.state() => pos_integer()}
  def counts(%__MODULE__{} = tasks) do
    tasks
    |> tree()
    |> Enum.map(&node_state/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  @doc """
  The tasks as a tree, flattened in display order.

  Top-level tasks come needs-you first, then working, waiting, failed and done, the most recently changed first within a state. Each task is followed by its subagents, foreground subagents before background ones, at depth 1.
  """
  @spec tree(t()) :: [node_t()]
  def tree(%__MODULE__{entries: entries}) do
    children = Enum.group_by(Map.values(entries), & &1.parent)

    entries
    |> Map.values()
    |> Enum.filter(&root?(&1, entries))
    |> Enum.sort_by(&sort_key/1)
    |> Enum.flat_map(fn entry ->
      [%{item: entry, depth: 0, parent: nil} | subagent_nodes(entry, children)]
    end)
  end

  @doc "True when no task is followed."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{entries: entries}), do: map_size(entries) == 0

  @spec subagent_nodes(Entry.t(), %{(pid() | nil) => [Entry.t()]}) :: [node_t()]
  defp subagent_nodes(%Entry{pid: pid, subagents: foreground}, children) do
    background = children |> Map.get(pid, []) |> Enum.sort_by(& &1.seq)

    Enum.map(foreground ++ background, &%{item: &1, depth: 1, parent: pid})
  end

  @spec node_state(node_t()) :: Entry.state() | nil
  defp node_state(%{item: %Entry{} = entry}), do: Entry.state(entry)
  defp node_state(%{item: %Subagent{state: state}}), do: state

  @spec root?(Entry.t(), %{pid() => Entry.t()}) :: boolean()
  defp root?(%Entry{parent: nil}, _entries), do: true
  defp root?(%Entry{parent: parent}, entries), do: not Map.has_key?(entries, parent)

  @spec sort_key(Entry.t()) :: {non_neg_integer(), integer(), integer()}
  defp sort_key(entry),
    do: {Map.fetch!(@state_rank, Entry.state(entry)), -entry.changed_at, -entry.seq}

  @spec ensure(t(), pid(), integer()) :: {t(), Entry.t()}
  defp ensure(%__MODULE__{entries: entries, next_seq: seq} = tasks, pid, now) do
    case Map.fetch(entries, pid) do
      {:ok, entry} -> {tasks, entry}
      :error -> {%{tasks | next_seq: seq + 1}, Entry.new(pid, seq, now)}
    end
  end

  @spec put(t(), Entry.t()) :: t()
  defp put(%__MODULE__{entries: entries} = tasks, %Entry{pid: pid} = entry),
    do: %{tasks | entries: Map.put(entries, pid, entry)}

  @spec update_entry(t(), pid(), (Entry.t() -> Entry.t())) :: t()
  defp update_entry(%__MODULE__{entries: entries} = tasks, pid, fun) do
    case Map.fetch(entries, pid) do
      {:ok, entry} -> put(tasks, fun.(entry))
      :error -> tasks
    end
  end

  @spec maybe(Entry.t(), term(), (Entry.t(), term() -> Entry.t())) :: Entry.t()
  defp maybe(entry, nil, _fun), do: entry
  defp maybe(entry, value, fun), do: fun.(entry, value)
end
