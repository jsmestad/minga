defmodule Minga.Buffer.UndoHistory do
  @moduledoc """
  Undo and redo history for a buffer, separate for you and for Minga, over one record of who wrote each byte.

  Every change to the document is recorded in a `Minga.Buffer.Provenance` value, which knows the author of every byte and keeps deleted text as tombstones. This module decides which history group each change belongs to:

  * **Yours.** Edits from you (`:user`), from a language server or formatter you invoked (`:lsp`), and from swap recovery (`:recovery`) form your undo stack. Rapid edits from the same source coalesce into one group within `coalesce_ms/0`. The stack keeps your last 1000 groups; an older group becomes permanent text that keeps its author.
  * **Minga's.** Each step of a Minga task (an author key, `Minga.Buffer.Author.key/0`) is its own group, never coalesced with another step or task and never evicted. An agent edit without a task (`:agent`) is a group of its own whose text is unattributed. Minga's groups never enter your stacks.

  `undo/3` and `redo/3` move only your groups. They find a group's text by its runs, not by byte offsets, so they stay exact when Minga edited above, below, or inside your text since. When flipping your group would change text that a later Minga step rewrote, they change nothing and return `{:blocked, {:overlaps, minga_group}}`. Minga's edits never clear your redo stack.

  Undo and redo restore the buffer version and cursor of the state they return to only when nothing else changed the document since that state; otherwise the restore asks for a new version (`:advance`), because the document is one no earlier version named, and the cursor goes to the first change.

  This module is pure state. It does not mark buffers dirty, broadcast events, or keep a clock; the buffer process supplies versions, documents, and monotonic times.
  """

  alias Minga.Buffer.Author
  alias Minga.Buffer.Document
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Position
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.UndoHistory.Entry
  alias Minga.Buffer.UndoHistory.Restore
  alias Minga.Buffer.UndoPatch

  require Author
  import EditSource, only: [is_undo_source: 1]

  @max_entries 1000
  @coalesce_ms 300
  @your_sources [:user, :lsp, :recovery]

  @type edit_source :: EditSource.undo_source()
  @type version :: non_neg_integer()
  @type patches :: nonempty_list(UndoPatch.t())
  @typedoc "Monotonic timestamp in milliseconds, supplied by the caller so this module stays clock-free."
  @type at :: integer()

  @typedoc "A change applied to the document: start byte, removed bytes, inserted bytes."
  @type change :: {non_neg_integer(), binary(), binary()}

  @typedoc "The Minga step whose later edit blocks your undo or redo; `:agent` for an agent edit without a task."
  @type minga_group :: Author.key() | :agent

  @typedoc "Why your undo or redo did not happen: a later Minga step rewrote the same text."
  @type blocked :: {:blocked, {:overlaps, minga_group()}}

  @typedoc "A Minga step and the byte ranges it touched, as `Minga.Buffer.Provenance.regions/2` reports them."
  @type minga_change :: {Author.key(), [Provenance.byte_range()]}

  # The newest stretch of history made only by one task's steps: the version and tick before it,
  # the tick after it, and whether the task had no remaining steps when it began. Reverting that
  # task while the history is still at `tick_after` returns exactly to `version`.
  @typep task_run :: %{
           task: Author.t() | :agent,
           version: version(),
           tick_before: Entry.tick(),
           tick_after: Entry.tick(),
           fresh: boolean()
         }

  @typep flip_group ::
           (Provenance.t(), Provenance.group_id(), Document.t() ->
              {:ok, Document.t(), non_neg_integer() | nil, Provenance.t()}
              | {:error, UndoPatch.apply_error()})

  defstruct provenance: Provenance.new(0),
            undo_entries: [],
            undo_size: 0,
            redo_entries: [],
            minga: [],
            steps: %{},
            task_run: nil,
            tick: 0,
            next_tick: 1,
            last_recorded_at: 0

  @opaque t :: %__MODULE__{
            provenance: Provenance.t(),
            undo_entries: [Entry.t()],
            undo_size: non_neg_integer(),
            redo_entries: [Entry.t()],
            minga: [{Provenance.group_id(), minga_group()}],
            steps: %{Author.key() => Provenance.group_id()},
            task_run: task_run() | nil,
            tick: Entry.tick(),
            next_tick: Entry.tick(),
            last_recorded_at: integer()
          }

  @doc "Creates an empty history for `document`, whose text all predates tracking."
  @spec new(Document.t()) :: t()
  def new(%Document{} = document \\ Document.new("")),
    do: %__MODULE__{provenance: Provenance.new(Document.content_byte_size(document))}

  @doc "Forgets all history and authorship and starts again for `document`."
  @spec reset(t(), Document.t()) :: t()
  def reset(%__MODULE__{}, %Document{} = document), do: new(document)

  @doc "Returns the coalescing window in milliseconds."
  @spec coalesce_ms() :: pos_integer()
  def coalesce_ms, do: @coalesce_ms

  @doc "Returns who wrote each byte of the document."
  @spec provenance(t()) :: Provenance.t()
  def provenance(%__MODULE__{provenance: provenance}), do: provenance

  @doc """
  Records an edit's patch, or the patches of one edit in undo order, at monotonic time `at`.

  Your edit joins your newest group when it has the same source, follows it within the coalescing window, and nothing else changed the document since. A Minga step joins its own group.
  """
  @spec record_edit(t(), version(), UndoPatch.t() | patches(), edit_source(), at()) :: t()
  def record_edit(%__MODULE__{} = history, version, [_ | _] = patches, source, at)
      when is_undo_source(source) and is_integer(at) do
    if coalesces?(history, source, at),
      do: coalesce(history, patches, at),
      else: record_edit_batch(history, version, patches, source, at)
  end

  def record_edit(%__MODULE__{} = history, version, patch, source, at),
    do: record_edit(history, version, [patch], source, at)

  @doc """
  Records one group containing all patches of a batch, stamped at monotonic time `at`.

  The patches are in undo order: the last patch in the list was applied to the document first, and each patch's offsets are in the document it was applied to. Your edit replaces your redo stack; a Minga edit leaves it alone.
  """
  @spec record_edit_batch(t(), version(), patches(), edit_source(), at()) :: t()
  def record_edit_batch(%__MODULE__{} = history, version, [_ | _] = patches, source, at)
      when source in @your_sources and is_integer(at) do
    history = drop_redo(history)
    {group, provenance} = Provenance.open_group(history.provenance, :you, nil)
    {tick, history} = advance(history)

    entry = %Entry{
      group: group,
      source: source,
      version: version,
      cursor: patches |> List.last() |> UndoPatch.cursor(),
      tick_from: tick,
      tick_to: history.tick
    }

    cap_entries(%{
      history
      | provenance: replay(provenance, group, patches),
        undo_entries: [entry | history.undo_entries],
        undo_size: history.undo_size + 1,
        tick: tick,
        last_recorded_at: at
    })
  end

  def record_edit_batch(%__MODULE__{} = history, version, [_ | _] = patches, source, at)
      when is_undo_source(source) and is_integer(at) do
    task_run = extend_task_run(history, task_of(source), version)
    {group, history} = minga_group(history, source)
    {tick, history} = advance(history)

    %{
      history
      | provenance: replay(history.provenance, group, patches),
        tick: tick,
        task_run: %{task_run | tick_after: tick}
    }
  end

  @doc "Records an edit's patch as a group of its own, stamped at monotonic time `at`. Later edits may still coalesce into it."
  @spec record_edit_force(t(), version(), UndoPatch.t(), edit_source(), at()) :: t()
  def record_edit_force(%__MODULE__{} = history, version, patch, source, at)
      when is_undo_source(source) and is_integer(at) do
    record_edit_batch(history, version, [patch], source, at)
  end

  @doc """
  Records changes that no history can take back, such as text appended to a log buffer.

  `changes` are in the order they were applied. Their inserted text is unattributed.
  """
  @spec record_untracked(t(), [change()]) :: t()
  def record_untracked(%__MODULE__{} = history, changes) when is_list(changes) do
    provenance =
      Enum.reduce(changes, history.provenance, fn {start, removed, inserted}, acc ->
        Provenance.edit(acc, :untracked, start, removed, inserted)
      end)

    {tick, history} = advance(history)
    %{history | provenance: provenance, tick: tick}
  end

  @doc """
  Undoes your newest group and returns the document without it.

  Returns `:empty` when you have nothing to undo, and `{:blocked, {:overlaps, minga_group}}` when a later Minga step rewrote text the group wrote or removed; then nothing changes. Returns `{:error, reason}` and leaves the history unchanged when the group's text does not fit `current_document`.
  """
  @spec undo(t(), version(), Document.t()) ::
          {:ok, Restore.t(), t()} | :empty | blocked() | {:error, UndoPatch.apply_error()}
  def undo(%__MODULE__{undo_entries: []}, _current_version, %Document{}), do: :empty

  def undo(%__MODULE__{undo_entries: [entry | rest]} = history, current_version, document) do
    with {:ok, restore, redo_entry, history} <-
           flip(history, entry, current_version, document, &Provenance.revert/3) do
      history = %{
        history
        | undo_entries: rest,
          undo_size: history.undo_size - 1,
          redo_entries: [redo_entry | history.redo_entries]
      }

      {:ok, restore, history}
    end
  end

  @doc "Redoes your newest undone group. Returns the same outcomes as `undo/3`."
  @spec redo(t(), version(), Document.t()) ::
          {:ok, Restore.t(), t()} | :empty | blocked() | {:error, UndoPatch.apply_error()}
  def redo(%__MODULE__{redo_entries: []}, _current_version, %Document{}), do: :empty

  def redo(%__MODULE__{redo_entries: [entry | rest]} = history, current_version, document) do
    with {:ok, restore, undo_entry, history} <-
           flip(history, entry, current_version, document, &Provenance.reapply/3) do
      history = %{
        history
        | redo_entries: rest,
          undo_entries: [undo_entry | history.undo_entries],
          undo_size: history.undo_size + 1
      }

      {:ok, restore, cap_entries(history)}
    end
  end

  @doc """
  Reverts every remaining step of the task that edited most recently, and forgets those steps.

  Agent edits without a task count as one task. Your text survives, including text you typed inside Minga's. When the task's steps are the newest changes and nothing else changed the document since they began, the restore returns the version from before them, so a buffer that was clean is clean again. Returns `{:ok, restore, history, reverted_steps}`, or `:empty` when Minga has no remaining steps in this buffer. When the steps' text does not fit `current_document`, returns `{:error, reason}` and the caller keeps its history and document unchanged.
  """
  @spec undo_agent_session(t(), version(), Document.t()) ::
          {:ok, Restore.t(), t(), pos_integer()} | :empty | {:error, UndoPatch.apply_error()}
  def undo_agent_session(%__MODULE__{minga: []}, _current_version, %Document{}), do: :empty

  def undo_agent_session(%__MODULE__{minga: [{_group, newest} | _]} = history, _version, document) do
    task = task_of(newest)
    {steps, others} = Enum.split_with(history.minga, fn {_group, key} -> task_of(key) == task end)

    with {:ok, reverted, first, provenance} <-
           revert_steps(steps, history.provenance, document, nil) do
      provenance =
        Enum.reduce(steps, provenance, fn {group, _key}, acc -> Provenance.discard(acc, group) end)

      {version, tick, history} = settle_task(history, task)

      history = %{
        history
        | provenance: provenance,
          minga: others,
          steps: Map.drop(history.steps, Enum.map(steps, &elem(&1, 1))),
          tick: tick,
          task_run: nil
      }

      document = place_cursor(reverted, first, Document.cursor(document))
      {:ok, Restore.new(version, document, :agent), history, length(steps)}
    end
  end

  @doc "Returns the remaining Minga steps of task `task_id` in this buffer, oldest first, with the byte ranges each touched."
  @spec minga_changes(t(), Author.id()) :: [minga_change()]
  def minga_changes(%__MODULE__{} = history, task_id) when is_binary(task_id) do
    for {group, {:minga, ^task_id, _step} = key} <- Enum.reverse(history.minga),
        do: {key, Provenance.regions(history.provenance, group)}
  end

  @doc "Resets the coalescing timer so the next recorded edit creates a new undo entry."
  @spec break_coalescing(t()) :: t()
  def break_coalescing(%__MODULE__{} = history), do: %{history | last_recorded_at: 0}

  @doc "Returns the source of your newest undo group, or `nil` if undo is unavailable."
  @spec last_undo_source(t()) :: edit_source() | nil
  def last_undo_source(%__MODULE__{undo_entries: []}), do: nil
  def last_undo_source(%__MODULE__{undo_entries: [entry | _]}), do: entry.source

  @doc "Returns the source of your newest redo group, or `nil` if redo is unavailable."
  @spec last_redo_source(t()) :: edit_source() | nil
  def last_redo_source(%__MODULE__{redo_entries: []}), do: nil
  def last_redo_source(%__MODULE__{redo_entries: [entry | _]}), do: entry.source

  @doc "Returns how many groups you can undo."
  @spec undo_count(t()) :: non_neg_integer()
  def undo_count(%__MODULE__{undo_size: size}), do: size

  @doc "Returns how many groups you can redo."
  @spec redo_count(t()) :: non_neg_integer()
  def redo_count(%__MODULE__{redo_entries: entries}), do: length(entries)

  # ── Recording ───────────────────────────────────────────────────────

  @spec coalesces?(t(), edit_source(), at()) :: boolean()
  defp coalesces?(
         %__MODULE__{undo_entries: [%Entry{source: source} = top | _]} = history,
         source,
         at
       )
       when source in @your_sources do
    history.tick == top.tick_from and history.last_recorded_at != 0 and
      at - history.last_recorded_at < @coalesce_ms
  end

  defp coalesces?(_history, _source, _at), do: false

  @spec coalesce(t(), patches(), at()) :: t()
  defp coalesce(%__MODULE__{undo_entries: [top | rest]} = history, patches, at) do
    {tick, history} = advance(history)

    %{
      history
      | provenance: replay(history.provenance, top.group, patches),
        undo_entries: [%{top | tick_from: tick} | rest],
        tick: tick,
        last_recorded_at: at
    }
  end

  # A task's step continues the newest stretch of its steps when nothing else changed the
  # document since; otherwise it starts a new stretch at the current version and tick.
  @spec extend_task_run(t(), Author.t() | :agent, version()) :: task_run()
  defp extend_task_run(
         %__MODULE__{task_run: %{task: task, tick_after: tick} = run, tick: tick},
         task,
         _version
       ),
       do: run

  defp extend_task_run(history, task, version) do
    %{
      task: task,
      version: version,
      tick_before: history.tick,
      tick_after: history.tick,
      fresh: not Enum.any?(history.minga, fn {_group, key} -> task_of(key) == task end)
    }
  end

  # A task reverted right after its only stretch of steps returns the document to the version and
  # tick before that stretch, so a buffer that was clean is clean again.
  @spec settle_task(t(), Author.t() | :agent) :: {version() | :advance, Entry.tick(), t()}
  defp settle_task(
         %__MODULE__{task_run: %{task: task, tick_after: tick, fresh: true} = run, tick: tick} =
           history,
         task
       ),
       do: {run.version, run.tick_before, history}

  defp settle_task(history, _task) do
    {tick, history} = advance(history)
    {:advance, tick, history}
  end

  # A Minga step reuses its group; an agent edit without a task always opens one.
  @spec minga_group(t(), minga_group()) :: {Provenance.group_id(), t()}
  defp minga_group(history, :agent), do: open_minga_group(history, :unattributed, :agent)

  defp minga_group(history, key) when Author.is_key(key) do
    case history.steps do
      %{^key => group} -> {group, history}
      _new_step -> open_minga_group(history, Author.author(key), key)
    end
  end

  @spec open_minga_group(t(), Provenance.author(), minga_group()) :: {Provenance.group_id(), t()}
  defp open_minga_group(history, author, key) do
    {group, provenance} = Provenance.open_group(history.provenance, author, key)
    steps = if key == :agent, do: history.steps, else: Map.put(history.steps, key, group)

    {group,
     %{history | provenance: provenance, minga: [{group, key} | history.minga], steps: steps}}
  end

  # Patches are in undo order, so the document saw them last to first.
  @spec replay(Provenance.t(), Provenance.group_id(), patches()) :: Provenance.t()
  defp replay(provenance, group, patches) do
    patches
    |> Enum.reverse()
    |> Enum.reduce(provenance, fn patch, acc ->
      {start, removed, inserted} = UndoPatch.change(patch)
      Provenance.edit(acc, group, start, removed, inserted)
    end)
  end

  # A new edit of yours replaces whatever you had undone.
  @spec drop_redo(t()) :: t()
  defp drop_redo(%__MODULE__{redo_entries: []} = history), do: history

  defp drop_redo(history) do
    provenance =
      Enum.reduce(history.redo_entries, history.provenance, fn entry, acc ->
        Provenance.discard(acc, entry.group)
      end)

    %{history | provenance: provenance, redo_entries: []}
  end

  @spec cap_entries(t()) :: t()
  defp cap_entries(%__MODULE__{undo_size: size} = history) when size <= @max_entries,
    do: history

  defp cap_entries(history) do
    {kept, evicted} = Enum.split(history.undo_entries, @max_entries)

    provenance =
      Enum.reduce(evicted, history.provenance, fn entry, acc ->
        Provenance.discard(acc, entry.group)
      end)

    %{history | provenance: provenance, undo_entries: kept, undo_size: @max_entries}
  end

  @spec advance(t()) :: {Entry.tick(), t()}
  defp advance(history), do: {history.next_tick, %{history | next_tick: history.next_tick + 1}}

  # ── Undo and redo ───────────────────────────────────────────────────

  # Flips the entry's group and returns the restore and the entry for the opposite stack.
  @spec flip(t(), Entry.t(), version(), Document.t(), flip_group()) ::
          {:ok, Restore.t(), Entry.t(), t()} | blocked() | {:error, UndoPatch.apply_error()}
  defp flip(history, %Entry{} = entry, current_version, document, flip_group) do
    with :ok <- unblocked(history.provenance, entry.group),
         {:ok, flipped, first, provenance} <-
           flip_group.(history.provenance, entry.group, document) do
      {version, flipped, tick, history} = settle(history, entry, flipped, first)

      opposite = %Entry{
        entry
        | version: current_version,
          cursor: Document.cursor(document),
          tick_from: tick,
          tick_to: history.tick
      }

      history = %{history | provenance: provenance, tick: tick, last_recorded_at: 0}
      {:ok, Restore.new(version, flipped, entry.source), opposite, history}
    end
  end

  @spec unblocked(Provenance.t(), Provenance.group_id()) :: :ok | blocked()
  defp unblocked(provenance, group) do
    case Provenance.blocker(provenance, group) do
      nil -> :ok
      minga_group -> {:blocked, {:overlaps, minga_group}}
    end
  end

  # When nothing changed the document since the entry's state, the flip returns exactly to that
  # state, so its version, cursor and tick come back. Otherwise the document is new.
  @spec settle(t(), Entry.t(), Document.t(), non_neg_integer() | nil) ::
          {version() | :advance, Document.t(), Entry.tick(), t()}
  defp settle(
         %__MODULE__{tick: tick} = history,
         %Entry{tick_from: tick} = entry,
         document,
         _first
       ),
       do: {entry.version, Document.move_to(document, entry.cursor), entry.tick_to, history}

  defp settle(history, entry, document, first) do
    {tick, history} = advance(history)
    {:advance, place_cursor(document, first, entry.cursor), tick, history}
  end

  @spec revert_steps(
          [{Provenance.group_id(), minga_group()}],
          Provenance.t(),
          Document.t(),
          non_neg_integer() | nil
        ) ::
          {:ok, Document.t(), non_neg_integer() | nil, Provenance.t()}
          | {:error, UndoPatch.apply_error()}
  defp revert_steps([], provenance, document, first), do: {:ok, document, first, provenance}

  defp revert_steps([{group, _key} | rest], provenance, document, first) do
    with {:ok, document, changed, provenance} <- Provenance.revert(provenance, group, document) do
      revert_steps(rest, provenance, document, lowest(first, changed))
    end
  end

  @spec lowest(non_neg_integer() | nil, non_neg_integer() | nil) :: non_neg_integer() | nil
  defp lowest(nil, offset), do: offset
  defp lowest(offset, nil), do: offset
  defp lowest(a, b), do: min(a, b)

  # Puts the cursor at the first change, or at `fallback` when nothing changed.
  @spec place_cursor(Document.t(), non_neg_integer() | nil, Document.position()) :: Document.t()
  defp place_cursor(document, nil, fallback), do: Document.move_to(document, fallback)

  defp place_cursor(document, offset, _fallback),
    do: Document.move_to(document, Position.from_point(document, offset))

  @spec task_of(minga_group()) :: Author.t() | :agent
  defp task_of(:agent), do: :agent
  defp task_of(key), do: Author.author(key)
end
