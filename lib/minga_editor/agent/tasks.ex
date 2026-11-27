defmodule MingaEditor.Agent.Tasks do
  @moduledoc """
  Every task Minga is working on, as the editor sees it: one place for the tasks drawer, the modeline's needs-you count and notifications.

  A task is an agent session the editor follows, whichever workspace or tab shows it. The editor feeds every session event through `observe/4`, before it routes the event to the active conversation or a background tab, so a background task's approval is kept here instead of being dropped. Each session remains the authority: an approval answered anywhere is cleared here by the session's `{:approval_resolved, ...}` event, and a late answer is refused by the session.

  Pure: callers pass wall-clock times, and the owning workflow does all process work.
  """

  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.Tasks.Entry
  alias MingaEditor.Agent.Tasks.Starting
  alias MingaEditor.Agent.Tasks.Subagent

  @typedoc "A row of the task tree: a task, or a foreground subagent beneath one."
  @type node_t :: %{
          required(:item) => Entry.t() | Subagent.t() | Starting.t(),
          required(:depth) => non_neg_integer(),
          required(:parent) => pid() | nil,
          required(:parent_seq) => non_neg_integer() | nil,
          optional(:parent_task_id) => String.t() | nil
        }

  @type t :: %__MODULE__{
          entries: %{pid() => Entry.t()},
          starting: %{reference() => Starting.t()},
          next_seq: non_neg_integer()
        }

  defstruct entries: %{}, starting: %{}, next_seq: 0

  # Rows are ordered needs-you first (docs/design/surfaces.md, "Tasks"), then in the design tokens' state order.
  @state_rank %{
    needs_you: 0,
    working: 1,
    waiting: 2,
    stopped: 3,
    failed: 4,
    done: 5,
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

  @doc "Shows a task the drawer started before its session binds. Returns the tasks and the new row's sequence number."
  @spec start(t(), reference(), String.t(), integer()) :: {t(), non_neg_integer()}
  def start(%__MODULE__{next_seq: seq} = tasks, id, title, now)
      when is_reference(id) and is_binary(title) do
    starting = %Starting{id: id, seq: seq, title: title, started_at: now}
    # A new start clears the starts that failed before it; their reasons were shown on their rows.
    kept = Map.reject(tasks.starting, fn {_id, start} -> Starting.state(start) == :failed end)
    {%{tasks | next_seq: seq + 1, starting: Map.put(kept, id, starting)}, seq}
  end

  @doc "Turns a starting task into the task of the session that bound for it."
  @spec bind(t(), reference(), pid(), integer()) :: t()
  def bind(%__MODULE__{} = tasks, id, session, now) when is_pid(session) do
    case Map.pop(tasks.starting, id) do
      {nil, _starting} ->
        follow(tasks, session, now)

      {%Starting{title: title}, starting} ->
        follow(%{tasks | starting: starting}, session, now, title: title)
    end
  end

  @doc "Shows that a starting task's session could not start."
  @spec start_failed(t(), reference(), String.t()) :: t()
  def start_failed(%__MODULE__{} = tasks, id, message) do
    case Map.fetch(tasks.starting, id) do
      {:ok, starting} ->
        %{tasks | starting: Map.put(tasks.starting, id, Starting.fail(starting, message))}

      :error ->
        tasks
    end
  end

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

  @doc "Fetches only the task still bound to this exact conversation record."
  @spec fetch(t(), pid(), String.t()) :: {:ok, Entry.t()} | :error
  def fetch(%__MODULE__{} = tasks, pid, task_id) when is_binary(task_id) do
    case fetch(tasks, pid) do
      {:ok, %Entry{task_id: ^task_id}} = bound -> bound
      _other -> :error
    end
  end

  @doc """
  Every session with a turn that can be stopped now, with that turn, whichever workspace shows it.
  """
  @spec stoppable(t()) :: [{pid(), Entry.stop_target()}]
  def stoppable(%__MODULE__{entries: entries}) do
    for {pid, %Entry{stop_target: {_, _} = target}} <- entries, do: {pid, target}
  end

  @doc "The approval a task is waiting on, bound to its session."
  @spec approval(t(), pid()) :: PendingApproval.t() | nil
  def approval(%__MODULE__{entries: entries}, pid) do
    case Map.fetch(entries, pid) do
      {:ok, %Entry{approval: approval}} -> approval
      :error -> nil
    end
  end

  @doc """
  Whether the task of `pid` started or stopped needing you between `before` and `now`.

  `:started` when it needs you now and did not before (it was not followed, or it was in another state); `:ended` when it needed you before and no longer does; `:unchanged` otherwise. A task that keeps needing you, for example a question that arrives while an approval is pending, is `:unchanged`, so it alerts once.
  """
  @spec attention(t(), t(), pid()) :: :started | :ended | :unchanged
  def attention(%__MODULE__{} = before, %__MODULE__{} = now, pid) when is_pid(pid) do
    was? = needs_you?(before, pid)
    is? = needs_you?(now, pid)

    cond do
      is? and not was? -> :started
      was? and not is? -> :ended
      true -> :unchanged
    end
  end

  @doc "Records the \"needs you\" alert just posted for the task of `pid`."
  @spec post_alert(t(), pid(), <<_::128>>) :: t()
  def post_alert(%__MODULE__{} = tasks, pid, <<_::128>> = id),
    do: update_entry(tasks, pid, &Entry.post_alert(&1, id))

  @doc "Records that the alert posted for the task of `pid` was withdrawn."
  @spec withdraw_alert(t(), pid()) :: t()
  def withdraw_alert(%__MODULE__{} = tasks, pid),
    do: update_entry(tasks, pid, &Entry.withdraw_alert/1)

  @doc "The identity of the alert posted for the task of `pid` and not withdrawn yet, or nil."
  @spec posted_alert(t(), pid()) :: <<_::128>> | nil
  def posted_alert(%__MODULE__{entries: entries}, pid) do
    case Map.fetch(entries, pid) do
      {:ok, %Entry{alert: {:posted, id}}} -> id
      _none -> nil
    end
  end

  @doc "The session of the task alert `id` was posted for, posted or withdrawn since, while the task is followed."
  @spec alerted_session(t(), <<_::128>>) :: {:ok, pid()} | :error
  def alerted_session(%__MODULE__{entries: entries}, <<_::128>> = id) do
    Enum.find_value(entries, :error, fn
      {pid, %Entry{alert: {_posted_or_withdrawn, ^id}}} -> {:ok, pid}
      _other -> nil
    end)
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

  Top-level tasks come needs-you first, then working, waiting, stopped, failed and done, the most recently changed first within a state. Each task is followed by its subagents, foreground subagents before background ones, at depth 1. A session without a goal yet (`Entry.goal?/1`) is not shown.
  """
  @spec tree(t()) :: [node_t()]
  def tree(%__MODULE__{starting: starting} = tasks) do
    shown = shown(tasks)
    children = Enum.group_by(Map.values(shown), & &1.parent)

    shown
    |> Map.values()
    |> Enum.filter(&root?(&1, shown))
    |> Enum.concat(Map.values(starting))
    |> Enum.sort_by(&sort_key/1)
    |> Enum.flat_map(fn
      %Starting{} = start ->
        [%{item: start, depth: 0, parent: nil, parent_seq: nil}]

      entry ->
        [%{item: entry, depth: 0, parent: nil, parent_seq: nil} | subagent_nodes(entry, children)]
    end)
  end

  @doc "True when there is no task to show: no session with a goal and no task starting."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{starting: starting} = tasks),
    do: map_size(shown(tasks)) == 0 and map_size(starting) == 0

  @spec needs_you?(t(), pid()) :: boolean()
  defp needs_you?(%__MODULE__{entries: entries}, pid) do
    case Map.fetch(entries, pid) do
      {:ok, entry} -> Entry.state(entry) == :needs_you
      :error -> false
    end
  end

  @spec shown(t()) :: %{pid() => Entry.t()}
  defp shown(%__MODULE__{entries: entries}),
    do: Map.filter(entries, fn {_pid, entry} -> Entry.goal?(entry) end)

  @spec subagent_nodes(Entry.t(), %{(pid() | nil) => [Entry.t()]}) :: [node_t()]
  defp subagent_nodes(%Entry{pid: pid, seq: seq, task_id: task, subagents: foreground}, children) do
    background = children |> Map.get(pid, []) |> Enum.sort_by(& &1.seq)

    Enum.map(foreground ++ background, fn item ->
      %{item: item, depth: 1, parent: pid, parent_seq: seq, parent_task_id: task}
    end)
  end

  @spec node_state(node_t()) :: Entry.state() | nil
  defp node_state(%{item: %Entry{} = entry}), do: Entry.state(entry)
  defp node_state(%{item: %Starting{} = start}), do: Starting.state(start)
  defp node_state(%{item: %Subagent{state: state}}), do: state

  @spec root?(Entry.t(), %{pid() => Entry.t()}) :: boolean()
  defp root?(%Entry{parent: nil}, _entries), do: true
  defp root?(%Entry{parent: parent}, entries), do: not Map.has_key?(entries, parent)

  @spec sort_key(Entry.t() | Starting.t()) :: {non_neg_integer(), integer(), integer()}
  defp sort_key(%Starting{} = start),
    do: {Map.fetch!(@state_rank, Starting.state(start)), -start.started_at, -start.seq}

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
