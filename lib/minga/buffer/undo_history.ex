defmodule Minga.Buffer.UndoHistory do
  @moduledoc """
  Undo and redo history for a buffer, separate for you and for Minga, over one record of who wrote each byte.

  Every change to the document is recorded in a `Minga.Buffer.Provenance` value, which knows the author of every byte and keeps deleted text as tombstones. This module decides which history group each change belongs to:

  * **Yours.** Edits from you (`:user`), from a language server or formatter you invoked (`:lsp`), and from swap recovery (`:recovery`) form your undo stack. Rapid edits from the same source coalesce into one group within `coalesce_ms/0`. The stack keeps your last 1000 groups; an older group becomes permanent text that keeps its author.
  * **Minga's.** Each step of a Minga task (an author key, `Minga.Buffer.Author.key/0`) is its own group, never coalesced with another step or task and never evicted. An agent edit without a task (`:agent`) is a group of its own, written by `{:minga, :untasked}` and named `{:untasked, n}`; the last 1000 such groups stay revertable, and an older one becomes permanent text that keeps that author. Before it does, any undo or redo step of yours it blocks leaves your stacks, with everything below it, so no flip can rebuild text that never existed. Minga's groups never enter your stacks.

  `undo/3` and `redo/3` move only your groups. They find a group's text by its runs, not by byte offsets, so they stay exact when Minga edited above, below, or inside your text since. When flipping your group would change text that a later Minga step rewrote, they change nothing and return `{:blocked, {:overlaps, minga_group}}`. Minga's edits never clear your redo stack.

  Who wrote each byte follows the text only where an alignment proves it unchanged: line and word trims, the word comparison's equal segments, and lines unique on both sides. Anything else is part of the change, so unchanged text inside one long line past the word budget, or inside an unpaired span with no unique line, is credited to the writer; exact text and exact rejects come first. A single deletion inside a run of identical text takes another author's copy first. The slider's unit is the grapheme cluster as Unicode defines it (UAX #29, as `String.graphemes/1` segments): both ends of the deletion stay cluster boundaries, so a flag, a conjoining jamo syllable, a ZWJ sequence or a letter with its marks is never split. It segments a window bounded by line breaks within a fixed distance, so its cost stays linear; without such bounds the deletion stays where the patch put it. The changes the history records (trims, word tokens, anchored spans and one-pass batches) also start and end on cluster boundaries, and every recorded run boundary is a cut between code points, so a revert never leaves part of a cluster that never existed.

  A step's group takes a new edit only when nothing changed the document and no group was opened since its last edit; otherwise the step continues in a new group under the same key. Every dependency between groups then points from an older group to a newer one: a later group that rewrote a group's text, or a group that edited inside a Minga group's replacement (text a step wrote in place of other text).

  `reject_task/4` reverts all of a task's steps or nothing: a task that started later and rewrote its text, or an edit inside one of its replacements, refuses it, so a revert is exact or refused, never wrong text. Groups that revert together are checked as one set: text one of them wrote and one of them deleted stays dead when they revert, so a later deletion of it neither refuses a reject nor joins a press. A set is checked as a set whatever order a press visits its steps in: every step of the chosen task counts as reverting, a step found held leaves the set, and the walk repeats until the set stops changing, which happens within one repeat per step of the task because the held steps only grow. `undo_agent_session/3` works step by step: newest first, each step of the most recent task reverts together with the newer groups that depend on it, which may be other tasks' steps. A group of yours joins only when none of its text is visible and reverting it brings back nothing else it deleted; it then leaves your undo stack. Otherwise your newest such edit holds the step, and your `u` can always reach it. Per-change keep and reject (#4049) may refine these rules.

  Every Minga step is checked against a run budget. Past it, `compaction_wanted?/1` asks the owner to run `compact_slice/2`, which merges drafts (text a step wrote that a newer step of the same task rewrote) into the step that overwrote them; past twice the budget, the step itself merges drafts too, until it has removed as many runs as it added, examining at most six times as many, so a burst of steps pays for its own drafts as it goes and the owner's slices finish the rest. A step merges only where no other group touched a run between the two steps; a step merged away completely leaves its class and its key.

  Steps never merge while a group of yours newer than the oldest step of the class they would form can still be undone: history from before your latest edit compacts once that edit is final (it leaves your undo stack). That is the documented memory limit: when you type between Minga's rewrites of a whole file, nothing from before your edits merges, and each rewrite of a 12,000-line file adds about 13,000 runs (about 16 MB) until the over-budget warning fires and you revert tasks or your edits leave the undo history. Keeping Minga's changes (#4049) will make those steps final, which must drop their tombstones and records. Minga editing 20 lines of such a file 1,000 times with a typed word between stays under the budget, at about 23,000 runs and 24 MB. A merge changes no document and no refusal at the moment it runs. Merged steps form a class that always moves together: they flip and are discarded together. Later history can still tell merged steps apart, so merging has two consequences for `undo_agent_session/3`, and only these two:

  1. A press that reverts a merged step takes its whole class: the older half of the merge too, with anything that depends on it, where without compaction the older half would wait for a later press. For example, a press on one task that takes another task's step with it (because it rewrote that step) also takes the steps merged into that step.
  2. A hold on any member holds the class, and so does every step whose revert is tied to a member: a newer step that only had to revert with one, and an older step whose revert needs one. Only an edit of yours made after the merge can hold it; that edit is newer than the class, so your `u` reaches it before anything the class waits for.

  Either way the press is exact for its own record, never removes visible text of yours, and repeating the press and `u` finishes.

  A press stays on the task it chose while an edit of yours holds it: `u` reaches that edit first. It moves on to an older task in two cases: only a permanent edit holds the chosen task, which no undo can reach; or your next undo is itself blocked by a later Minga step, which a press must revert before `u` can go. Without the second case a press could wait for your undo while your undo waits for another task's step, with no merge involved.

  `reload/3` takes in content changed on disk without losing Minga's unreviewed steps.

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
  # Runs a recording may examine for compaction even when its step added few; see `compact_inline/2`.
  @inline_compaction_floor 2_000
  # Runs, tombstones included, past which a Minga step asks for draft compaction; measured, see the PR for #4048.
  @run_budget 25_000
  # Deleted text kept as tombstones past which compaction is asked for even under the run budget.
  @dead_text_budget 64 * 1024 * 1024
  @coalesce_ms 300
  @your_sources [:user, :lsp, :recovery]

  @type edit_source :: EditSource.undo_source()
  @type version :: non_neg_integer()
  @type patches :: nonempty_list(UndoPatch.t())
  @typedoc "Monotonic timestamp in milliseconds, supplied by the caller so this module stays clock-free."
  @type at :: integer()

  @typedoc """
  What one compaction slice did; see `compact_slice/2`. `merged` names each step merged into a newer step of its task, as `{older, newer}`, in the order they merged.
  """
  @type slice :: %{
          examined: non_neg_integer(),
          merged: [{minga_group(), minga_group()}],
          runs: non_neg_integer(),
          drafts: non_neg_integer()
        }

  @typedoc "How finely edits are recorded; see `new/2`."
  @type recording :: :precise | :coarse

  @typedoc "Steps compaction merged, as links between groups; a class of linked steps reverts as one."
  @type merges :: %{Provenance.group_id() => MapSet.t(Provenance.group_id())}

  @typedoc "A change applied to the document: start byte, removed bytes, inserted bytes."
  @type change :: {non_neg_integer(), binary(), binary()}

  @typedoc "A Minga step, or `{:untasked, n}` for the `n`th agent edit without a task."
  @type minga_group :: Author.key() | {:untasked, pos_integer()}

  @typedoc "A task whose steps revert together: Minga in a task, or Minga's agent edits without a task."
  @type task :: Author.t() | {:minga, :untasked}

  @typedoc "Why an undo, redo or revert did not happen: a later Minga step rewrote the same text."
  @type blocked :: {:blocked, {:overlaps, minga_group() | :you}}

  @typedoc """
  What holds a task's step: an edit of yours your `u` can reach, or a permanent edit (one that left your undo history, or a reload) that no undo reaches, with the byte offset of that edit.
  """
  @type hold :: {:yours | :permanent, non_neg_integer()}

  @typedoc """
  What one `undo_agent_session/3` call reverted; see there. `rounds` counts the walks the press needed before its set stopped changing: one, plus one for each time a step it counted as reverting turned out held.
  """
  @type reject_summary :: %{
          task: task(),
          reverted: non_neg_integer(),
          total: non_neg_integer(),
          tasks: [task()],
          groups: [Provenance.group_id()],
          dropped: [non_neg_integer()],
          held: hold() | nil,
          rounds: pos_integer()
        }

  @typedoc "A Minga step and the byte ranges it touched, as `Minga.Buffer.Provenance.regions/2` reports them."
  @type minga_change :: {Author.key(), [Provenance.byte_range()]}

  # The newest stretch of history made only by one task's steps.
  # It keeps the version and tick before it, the tick after it, and whether the task had no steps when it began.
  # Reverting that task while the history is still at `tick_after` returns exactly to `version`.
  @typep task_run :: %{
           task: task(),
           version: version(),
           tick_before: Entry.tick(),
           tick_after: Entry.tick(),
           fresh: boolean()
         }

  @typep flip_group ::
           (Provenance.t(), Provenance.group_id(), Document.t() ->
              {:ok, Document.t(), non_neg_integer() | nil, Provenance.t()}
              | {:error, UndoPatch.apply_error()})

  # `provenance` and `untasked` hold opaque values, so they have no literal defaults; `new/2` builds them.
  defstruct provenance: nil,
            undo_entries: [],
            undo_size: 0,
            redo_entries: [],
            minga: [],
            untasked: nil,
            untasked_size: 0,
            steps: %{},
            task_run: nil,
            task_ticks: %{},
            next_untasked: 1,
            tick: 0,
            next_tick: 1,
            last_recorded_at: 0,
            recording: :precise,
            task_started: %{},
            run_budget: @run_budget,
            compaction_wanted: false,
            over_budget_reported: false,
            before: nil,
            step_ticks: %{},
            merges: %{},
            inline_merged: []

  @opaque t :: %__MODULE__{
            provenance: Provenance.t(),
            undo_entries: [Entry.t()],
            undo_size: non_neg_integer(),
            redo_entries: [Entry.t()],
            minga: [{Provenance.group_id(), Author.key()}],
            untasked: :queue.queue(Provenance.group_id()),
            untasked_size: non_neg_integer(),
            steps: %{Author.key() => Provenance.group_id()},
            task_run: task_run() | nil,
            task_ticks: %{task() => Entry.tick()},
            next_untasked: pos_integer(),
            tick: Entry.tick(),
            next_tick: Entry.tick(),
            last_recorded_at: integer(),
            recording: recording(),
            task_started: %{Author.t() => Provenance.group_id()},
            run_budget: pos_integer(),
            compaction_wanted: boolean(),
            over_budget_reported: boolean(),
            before: Document.t() | nil,
            step_ticks: %{Provenance.group_id() => Entry.tick()},
            merges: %{Provenance.group_id() => MapSet.t(Provenance.group_id())},
            inline_merged: [{minga_group(), minga_group()}]
          }

  @doc """
  Creates an empty history for `document`, whose text all predates tracking.

  Options:

  * `:run_budget` - how many runs, tombstones included, the history keeps before `compaction_wanted?/1` asks for draft compaction (default #{@run_budget}). See `compact_slice/2`.
  * `:recording` - `:precise` (the default) records each edit as its smallest changes. `:coarse` records each patch as one change, as a fallback would; tests use it to prove that a revert stays exact or is refused whatever the recording granularity.
  """
  @spec new(Document.t(), [{:recording, recording()} | {:run_budget, pos_integer()}]) :: t()
  def new(%Document{} = document \\ Document.new(""), opts \\ []) when is_list(opts) do
    %__MODULE__{
      provenance: Provenance.new(Document.content_byte_size(document)),
      untasked: :queue.new(),
      recording: Keyword.get(opts, :recording, :precise),
      run_budget: Keyword.get(opts, :run_budget, @run_budget)
    }
  end

  @doc "Forgets all history and authorship and starts again for `document`, keeping the history's options."
  @spec reset(t(), Document.t()) :: t()
  def reset(%__MODULE__{} = history, %Document{} = document),
    do: new(document, recording: history.recording, run_budget: history.run_budget)

  @doc "Returns the coalescing window in milliseconds."
  @spec coalesce_ms() :: pos_integer()
  def coalesce_ms, do: @coalesce_ms

  @doc "Returns the document size in bytes that the history describes, in O(1)."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{provenance: provenance}), do: Provenance.size(provenance)

  @doc """
  Takes in content read from disk, keeping Minga's steps.

  Your undo and redo groups end, as when you reopen a file: their text stays and keeps its author. Minga's tasked and untasked groups stay, so unreviewed work survives a reload. The difference from `old_document` to `new_document` is recorded as untracked, byte-precise changes, so unchanged text keeps its author.
  """
  @spec reload(t(), Document.t(), Document.t()) :: t()
  def reload(%__MODULE__{} = history, %Document{} = old_document, %Document{} = new_document) do
    provenance =
      Enum.reduce(history.undo_entries ++ history.redo_entries, history.provenance, fn entry,
                                                                                       acc ->
        Provenance.discard(acc, entry.group)
      end)

    provenance =
      replay(
        %{history | before: nil},
        provenance,
        :untracked,
        UndoPatch.changes(old_document, new_document)
      )

    {tick, history} = advance(history)

    %{
      history
      | provenance: provenance,
        undo_entries: [],
        undo_size: 0,
        redo_entries: [],
        tick: tick,
        task_run: nil,
        last_recorded_at: 0
    }
  end

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
      | provenance: replay(history, provenance, group, patches),
        undo_entries: [entry | history.undo_entries],
        undo_size: history.undo_size + 1,
        tick: tick,
        last_recorded_at: at
    })
  end

  def record_edit_batch(%__MODULE__{} = history, version, [_ | _] = patches, source, at)
      when is_undo_source(source) and is_integer(at) do
    task = task_of(source)
    task_run = extend_task_run(history, task, version)
    {group, history} = minga_group(history, source)
    {tick, history} = advance(history)
    runs_before = Provenance.run_count(history.provenance)
    provenance = replay(history, history.provenance, group, patches)

    %{
      history
      | provenance: provenance,
        tick: tick,
        task_run: %{task_run | tick_after: tick},
        task_ticks: Map.put(history.task_ticks, task, tick),
        step_ticks: remember_step_tick(history.step_ticks, source, group, tick)
    }
    |> cap_untasked()
    |> compact_inline(max(Provenance.run_count(provenance) - runs_before, 0))
    |> want_compaction()
  end

  # Backpressure for steps that arrive faster than the owner's slices run.
  # Past twice the budget, recording merges drafts until it has removed as many runs as the step added (or reached
  # twice the budget), examining at most six times the runs the step added (and at least a few thousand): a burst of
  # steps pays for its own drafts as it goes, so the runs stay bounded, and one call's work is proportional to its own
  # step. The owner's slices finish the rest.
  @spec compact_inline(t(), non_neg_integer()) :: t()
  defp compact_inline(history, added) do
    limit = 2 * history.run_budget
    runs = Provenance.run_count(history.provenance)

    if runs > limit do
      target = max(limit, runs - added)
      done? = &(Provenance.run_count(&1.provenance) <= target)
      work = max(6 * added, @inline_compaction_floor)
      {history, _examined, merged} = compact_until(history, work, 0, [], done?)
      %{history | inline_merged: merged ++ history.inline_merged}
    else
      history
    end
  end

  # Only a keyed step can resume its group; an untasked agent edit always opens a new one.
  @spec remember_step_tick(
          %{Provenance.group_id() => Entry.tick()},
          edit_source(),
          Provenance.group_id(),
          Entry.tick()
        ) ::
          %{Provenance.group_id() => Entry.tick()}
  defp remember_step_tick(ticks, :agent, _group, _tick), do: ticks
  defp remember_step_tick(ticks, _key, group, tick), do: Map.put(ticks, group, tick)

  # Checked after each Minga step: only Minga's steps make drafts.
  # Compaction is wanted while there are drafts to merge, or once to report history that stays over budget.
  @spec want_compaction(t()) :: t()
  defp want_compaction(history) do
    wanted =
      over_budget?(history) and
        (Provenance.draft_count(history.provenance) > 0 or not history.over_budget_reported)

    %{history | compaction_wanted: wanted}
  end

  @spec over_budget?(t()) :: boolean()
  defp over_budget?(history) do
    Provenance.run_count(history.provenance) > history.run_budget or
      Provenance.dead_bytes(history.provenance) > @dead_text_budget
  end

  # Compaction stops at three quarters of both budgets, so the next steps do not ask for it again at once.
  @spec under_target?(t()) :: boolean()
  defp under_target?(history) do
    Provenance.run_count(history.provenance) <= div(history.run_budget * 3, 4) and
      Provenance.dead_bytes(history.provenance) <= div(@dead_text_budget * 3, 4)
  end

  @doc """
  Gives the next recording the document as it was before the change, or forgets it with `nil`.

  A single deletion at the edge of a run of identical text can then slide along that run, by whole characters, to take another author's copy first; without it, the deletion stays where the patch put it.
  """
  @spec before_change(t(), Document.t() | nil) :: t()
  def before_change(%__MODULE__{} = history, document)
      when is_struct(document, Document) or is_nil(document),
      do: %{history | before: document}

  @doc """
  Returns the steps recording merged on the edit path since the last call, as `{older, newer}` in the order they merged, and the history without them. The owner names them in *Messages*, as it does a slice's.
  """
  @spec take_inline_merges(t()) :: {[{minga_group(), minga_group()}], t()}
  def take_inline_merges(%__MODULE__{inline_merged: merged} = history),
    do: {Enum.reverse(merged), %{history | inline_merged: []}}

  @doc "Returns whether a Minga step left the history over its run budget, so the owner should run `compact_slice/2`."
  @spec compaction_wanted?(t()) :: boolean()
  def compaction_wanted?(%__MODULE__{compaction_wanted: wanted}), do: wanted

  @doc """
  Merges drafts, oldest step first, until about `max_runs` runs were examined, the history is at 75% of its run budget, or no drafts remain.

  A draft is text a Minga step wrote that a newer step of the same task rewrote, with both steps still unreviewed. Merging the older step into the newer one across the stretch around the draft drops the draft and keeps, at that moment, the document, the text of every undo, redo and reject, and every refusal (though a refusal may name the newer step). Only reverting the newer step alone, which no command does, now also reverts the older one there. A step left with no text leaves the history.

  Returns `{:more, history, slice}` while there is more to do, or `{:done, history, slice}`; `{:over_budget, history, slice}` the first time the history is still over budget with no drafts left, so the owner can warn once per history.
  """
  @spec compact_slice(t(), pos_integer()) :: {:more | :done | :over_budget, t(), slice()}
  def compact_slice(%__MODULE__{} = history, max_runs)
      when is_integer(max_runs) and max_runs > 0 do
    {history, examined, merged} = compact_until(history, max_runs, 0, [])
    provenance = history.provenance

    slice = %{
      examined: examined,
      merged: Enum.reverse(merged),
      runs: Provenance.run_count(provenance),
      drafts: Provenance.draft_count(provenance)
    }

    cond do
      # Drafts the slice could not merge (a merge around an edit of yours is refused) leave nothing more to do.
      not under_target?(history) and slice.drafts > 0 and merged != [] ->
        {:more, history, slice}

      over_budget?(history) and not history.over_budget_reported ->
        {:over_budget, %{history | compaction_wanted: false, over_budget_reported: true}, slice}

      true ->
        {:done, %{history | compaction_wanted: false}, slice}
    end
  end

  @spec compact_until(
          t(),
          pos_integer(),
          non_neg_integer(),
          [{minga_group(), minga_group()}],
          (t() -> boolean())
        ) ::
          {t(), non_neg_integer(), [{minga_group(), minga_group()}]}
  defp compact_until(history, max_runs, examined, merged, done? \\ &under_target?/1) do
    if examined >= max_runs or done?.(history) do
      {history, examined, merged}
    else
      case Provenance.compact_oldest(history.provenance, &merge_class(history.merges, &1)) do
        :none ->
          {history, examined, merged}

        {:ok, provenance, {old, new}, runs} ->
          pair =
            {Provenance.group_key(history.provenance, old), Provenance.group_key(provenance, new)}

          merges = merge_partners(history.merges, old, new, Provenance.group?(provenance, old))
          history = forget_empty_step(%{history | merges: merges}, old, provenance)
          compact_until(history, max_runs, examined + runs, [pair | merged], done?)
      end
    end
  end

  # A step whose text all moved into a newer step of its task is gone from the provenance, so its key goes too; a
  # later edit with that key opens a new group.
  @spec forget_empty_step(t(), Provenance.group_id(), Provenance.t()) :: t()
  defp forget_empty_step(history, old, provenance) do
    if Provenance.group?(provenance, old) do
      %{history | provenance: provenance}
    else
      {_old, key} = List.keyfind(history.minga, old, 0)

      # The key goes only if it still names `old`: a newer group of the same step may hold it now.
      steps =
        case history.steps do
          %{^key => ^old} -> Map.delete(history.steps, key)
          _newer -> history.steps
        end

      %{
        history
        | provenance: provenance,
          minga: List.keydelete(history.minga, old, 0),
          steps: steps,
          step_ticks: Map.delete(history.step_ticks, old)
      }
    end
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
  Reverts, in one call, every step of the task that edited most recently that can be reverted exactly, and forgets them. See `reject_task/4`.

  It works on the task that edited most recently; when that task cannot revert any step, it tries the next most recent, so a press reverts something whenever any task can. Steps are visited newest first. A step reverts together with everything newer that depends on it: a later group that rewrote its text, and a group that edited inside one of its replacements. Another task's step among them reverts with it. A group of yours among them joins only when none of its text is visible and reverting it brings back nothing else it deleted; it leaves your undo stack. Otherwise the step is held by your newest such edit, which your `u` can always reach, and older steps are still tried.

  Returns `{:ok, restore, history, summary}` when at least one step reverted, where `summary` holds the task, the steps reverted (`:reverted`) and the task's steps at the start (`:total`), the other tasks whose steps reverted with them (`:tasks`), the groups reverted (`:groups`), the byte offsets of edits of yours dropped from your undo stack (`:dropped`), and the byte offset of your edit that holds the rest (`:held`, or `nil`). Returns `{:blocked, {:overlaps, :you}, task, offset}` when no step could revert, and `:empty` when Minga has no steps left in the buffer.
  """
  @spec undo_agent_session(t(), version(), Document.t()) ::
          {:ok, Restore.t(), t(), reject_summary()}
          | :empty
          | {:blocked, {:overlaps, :you}, task(), hold()}
          | {:error, UndoPatch.apply_error()}
  def undo_agent_session(%__MODULE__{} = history, _version, %Document{} = document) do
    history.task_ticks
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.reduce_while(:empty, fn {task, _tick}, first_held ->
      case reject_steps(history, task, document) do
        {:blocked, _overlap, _task, _offset} = held -> held_press(history, task, held, first_held)
        reverted_or_error -> {:halt, reverted_or_error}
      end
    end)
  end

  # A press stays on the task it chose while an edit of yours holds it: `u` reaches that edit first. It moves on past a
  # task only a permanent edit holds, which no undo can reach, or when your next undo is itself blocked by a later
  # Minga step, which a press must revert first. It reports the hold it stopped on, or the first it met when every
  # task was held.
  @spec held_press(t(), task(), tuple(), :empty | tuple()) :: {:halt | :cont, tuple()}
  defp held_press(history, task, held, first_held) do
    cond do
      held_by_your_undo?(history, task) -> {:halt, held}
      first_held == :empty -> {:cont, held}
      true -> {:cont, first_held}
    end
  end

  # Whether a group of yours holds one of the task's steps and your next `u` can go: then that `u` is the way forward.
  # When your next undo is itself blocked by a later Minga step, that step's task is the way forward instead.
  @spec held_by_your_undo?(t(), task()) :: boolean()
  defp held_by_your_undo?(history, task) do
    your_undo_free?(history) and
      history
      |> task_groups(task)
      |> Enum.any?(fn group ->
        closure =
          dependents(
            history.provenance,
            history.merges,
            [group],
            MapSet.new([group]),
            &no_group/1
          )

        match?({:group, _holding}, held_in(history.provenance, closure))
      end)
  end

  @spec your_undo_free?(t()) :: boolean()
  defp your_undo_free?(%__MODULE__{undo_entries: [entry | _rest]} = history),
    do: Provenance.blocker(history.provenance, entry.group) == nil

  defp your_undo_free?(_history), do: false

  @doc "Returns the task `undo_agent_session/3` works on next: the one that edited most recently, or `nil`."
  @spec next_reject(t()) :: task() | nil
  def next_reject(%__MODULE__{task_ticks: ticks}) when map_size(ticks) == 0, do: nil

  def next_reject(%__MODULE__{task_ticks: ticks}),
    do: ticks |> Enum.max_by(&elem(&1, 1)) |> elem(0)

  @spec reject_steps(t(), task(), Document.t()) ::
          {:ok, Restore.t(), t(), reject_summary()}
          | {:blocked, {:overlaps, :you}, task(), hold()}
          | {:error, UndoPatch.apply_error()}
  defp reject_steps(history, task, document) do
    total = history |> task_groups(task) |> step_count(history)

    start = %{
      history: history,
      document: document,
      groups: [],
      dropped: [],
      first: nil,
      rounds: 0
    }

    with {:ok, walk} <- walk_steps(start, task) do
      finish_walk(history, walk, task, total)
    end
  end

  # Visits the task's remaining groups newest first and reverts each one whose dependents can go with it.
  @spec walk_steps(map(), task()) :: {:ok, map()} | {:error, UndoPatch.apply_error()}
  # Every decision reads only which groups are applied, so the walk decides on flags (a closure it takes is marked
  # unapplied for the decisions after it) and then reverts everything it took in one pass and discards it once. Each
  # step's closure costs the runs of the groups in it. When nothing is held, closures taken are skipped later, so the
  # press costs the task's runs plus one pass over the document. A held closure is walked again by each older step
  # that reaches it, so a chain of T held steps over the same text costs O(T^2) group visits. Remembering held
  # closures is not sound here: a larger reverting set can leave out a dependent through which the hold was reached.
  #
  # A set is checked as a set: every step of the task counts as reverting while the walk decides, so the order of the
  # walk changes nothing. A step found held leaves the set and the walk repeats; the held steps only grow, so the walk
  # repeats at most once per step of the task, and only when one is held.
  defp walk_steps(walk, task) do
    steps = walk.history |> task_groups(task) |> Enum.sort(:desc)
    {taken, rounds} = settle_walk(walk, steps, [], 1)
    walk = %{walk | rounds: rounds}
    if MapSet.size(taken) == 0, do: {:ok, walk}, else: revert_groups(walk, taken)
  end

  # `held_out` lists the steps found held so far; they no longer count as reverting.
  @spec settle_walk(map(), [Provenance.group_id()], [Provenance.group_id()], pos_integer()) ::
          {MapSet.t(), pos_integer()}
  defp settle_walk(walk, steps, held_out, round) do
    pool = MapSet.new(steps -- held_out)
    {taken, held} = walk_once(walk, steps, pool)

    case held -- held_out do
      [] -> {taken, round}
      newly_held -> settle_walk(walk, steps, newly_held ++ held_out, round + 1)
    end
  end

  # One pass over the task's steps, newest first, with `pool` counting as reverting; returns what it took and which of
  # the task's steps it found held, as a list.
  @spec walk_once(map(), [Provenance.group_id()], MapSet.t()) ::
          {MapSet.t(), [Provenance.group_id()]}
  defp walk_once(walk, steps, pool) do
    {_flags, taken, held} =
      Enum.reduce(
        steps,
        {walk.history.provenance, MapSet.new(), []},
        &visit_step(walk, pool, &1, &2)
      )

    {taken, held}
  end

  @spec visit_step(
          map(),
          MapSet.t(),
          Provenance.group_id(),
          {Provenance.t(), MapSet.t(), [Provenance.group_id()]}
        ) ::
          {Provenance.t(), MapSet.t(), [Provenance.group_id()]}
  defp visit_step(walk, pool, group, {_flags, taken, _held} = acc) do
    if MapSet.member?(taken, group), do: acc, else: decide_step(walk, pool, group, acc)
  end

  @spec decide_step(
          map(),
          MapSet.t(),
          Provenance.group_id(),
          {Provenance.t(), MapSet.t(), [Provenance.group_id()]}
        ) ::
          {Provenance.t(), MapSet.t(), [Provenance.group_id()]}
  defp decide_step(walk, pool, group, {flags, taken, held}) do
    case take_closure(walk, flags, taken, pool, group) do
      {:taken, flags, taken} -> {flags, taken, held}
      :held -> {flags, taken, [group | held]}
    end
  end

  @spec take_closure(map(), Provenance.t(), MapSet.t(), MapSet.t(), Provenance.group_id()) ::
          {:taken, Provenance.t(), MapSet.t()} | :held
  defp take_closure(walk, flags, taken, pool, group) do
    closure =
      dependents(
        flags,
        walk.history.merges,
        [group],
        MapSet.new([group]),
        &(MapSet.member?(taken, &1) or MapSet.member?(pool, &1))
      )

    case held_in(flags, closure) do
      nil ->
        groups = closure |> MapSet.delete(:permanent) |> MapSet.to_list()
        {:taken, Provenance.assume_unapplied(flags, groups), Enum.into(groups, taken)}

      _held ->
        :held
    end
  end

  @spec no_group(Provenance.group_id()) :: false
  defp no_group(_group), do: false

  # Everything newer that must revert with these groups: for a Minga group, later Minga groups that rewrote its text
  # and the groups that edited inside its replacements; for a group of yours, the Minga groups that rewrote it. A
  # permanent mark stands for an edit that can never revert. Every edge points to a newer group, so the walk ends.
  # Steps compaction merged are one node: each brings its whole merge class, so a class never reverts in halves.
  # Text the closure and the groups this press already took (`taken?`) both wrote and deleted stays dead when they all
  # revert, so a later deletion of it adds nothing.
  @spec dependents(
          Provenance.t(),
          merges(),
          [Provenance.group_id() | :permanent],
          MapSet.t(),
          (Provenance.group_id() -> boolean())
        ) :: MapSet.t()
  defp dependents(_provenance, _merges, [], closure, _taken?), do: closure

  defp dependents(provenance, merges, [:permanent | rest], closure, taken?),
    do: dependents(provenance, merges, rest, closure, taken?)

  defp dependents(provenance, merges, [group | rest], closure, taken?) do
    reverting? = &(MapSet.member?(closure, &1) or taken?.(&1))

    found =
      (direct_dependents(provenance, group, reverting?) ++ merge_class(merges, group))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(closure, &1))

    dependents(provenance, merges, found ++ rest, Enum.into(found, closure), taken?)
  end

  @doc """
  Returns the steps that compaction merged with `group`, directly or through other merged steps, `group` included. They revert together.
  """
  @spec merge_class(t() | merges(), Provenance.group_id()) :: [Provenance.group_id()]
  def merge_class(%__MODULE__{merges: merges}, group), do: merge_class(merges, group)

  def merge_class(merges, group) when is_map(merges),
    do: merges |> class_from([group], MapSet.new([group])) |> MapSet.to_list()

  @spec class_from(merges(), [Provenance.group_id()], MapSet.t()) :: MapSet.t()
  defp class_from(_merges, [], seen), do: seen

  defp class_from(merges, [group | rest], seen) do
    next = merges |> Map.get(group, MapSet.new()) |> Enum.reject(&MapSet.member?(seen, &1))
    class_from(merges, next ++ rest, Enum.into(next, seen))
  end

  # Compaction merged `old` into `new`. While `old` keeps runs of its own the two are linked; once it has none, its
  # other partners link to `new` instead, and it leaves its class.
  @spec merge_partners(merges(), Provenance.group_id(), Provenance.group_id(), boolean()) ::
          merges()
  defp merge_partners(merges, old, new, true), do: merges |> link(old, new) |> link(new, old)

  defp merge_partners(merges, old, new, false) do
    merges
    |> Map.get(old, MapSet.new())
    |> MapSet.delete(new)
    |> Enum.reduce(merges, fn partner, acc -> acc |> link(partner, new) |> link(new, partner) end)
    |> unlink(old)
  end

  @spec link(merges(), Provenance.group_id(), Provenance.group_id()) :: merges()
  defp link(merges, from, to), do: Map.update(merges, from, MapSet.new([to]), &MapSet.put(&1, to))

  # Takes a group out of its class, keeping the rest of the class connected.
  @spec unlink(merges(), Provenance.group_id()) :: merges()
  defp unlink(merges, group) do
    {partners, merges} = Map.pop(merges, group, MapSet.new())
    partners = MapSet.to_list(partners)

    merges =
      for a <- partners, b <- partners, a != b, reduce: merges do
        acc -> link(acc, a, b)
      end

    Enum.reduce(partners, merges, fn partner, acc ->
      rest = acc |> Map.get(partner, MapSet.new()) |> MapSet.delete(group)
      if MapSet.size(rest) == 0, do: Map.delete(acc, partner), else: Map.put(acc, partner, rest)
    end)
  end

  # The applied Minga groups that deleted, after `group`, a run it wrote or deleted in any way (covers included: your
  # deletion and a later cover of the same text both keep it dead, so they revert together), leaving out text the
  # reverting groups both wrote and deleted; and the groups that marked its replacement.
  @spec direct_dependents(Provenance.t(), Provenance.group_id(), (term() -> boolean())) :: [
          Provenance.group_id() | :permanent
        ]
  defp direct_dependents(provenance, group, reverting?) do
    rewriters = Provenance.later_deleters_of(provenance, group, reverting?)

    if Provenance.group_key(provenance, group) == nil do
      rewriters
    else
      overlaps =
        for {overlap, _offset} <- Provenance.overlapping_groups(provenance, [group]),
            do: overlap_node(overlap)

      Enum.uniq(rewriters ++ overlaps)
    end
  end

  @spec overlap_node(Provenance.group_id() | {:permanent, term()}) ::
          Provenance.group_id() | :permanent
  defp overlap_node(group) when is_integer(group), do: group
  defp overlap_node({:permanent, _key}), do: :permanent

  # Where an edit of yours holds a closure: a permanent edit, or a group of yours with visible text or whose revert
  # would bring back other text it deleted. The newest such group of yours is named; your `u` reaches it first.
  @spec held_in(Provenance.t(), MapSet.t()) ::
          {:group, Provenance.group_id()} | {:offset, non_neg_integer()} | nil
  defp held_in(provenance, closure) do
    reverted = closure |> MapSet.delete(:permanent) |> MapSet.to_list()
    yours = for group <- reverted, Provenance.group_key(provenance, group) == nil, do: group

    holding =
      yours
      |> Enum.sort(:desc)
      |> Enum.find(
        &(Provenance.live_bytes_of(provenance, &1) > 0 or
            Provenance.revives_deleted?(provenance, &1, reverted))
      )

    cond do
      holding != nil -> {:group, holding}
      MapSet.member?(closure, :permanent) -> {:offset, permanent_offset(provenance, reverted)}
      true -> nil
    end
  end

  @spec permanent_offset(Provenance.t(), [Provenance.group_id()]) :: non_neg_integer()
  defp permanent_offset(provenance, groups) do
    minga = Enum.reject(groups, &(Provenance.group_key(provenance, &1) == nil))

    provenance
    |> Provenance.overlapping_groups(minga)
    |> Enum.find_value(0, fn
      {{:permanent, _key}, offset} -> offset
      _other -> nil
    end)
  end

  @spec group_offset(Provenance.t(), Provenance.group_id()) :: non_neg_integer()
  defp group_offset(provenance, group) do
    case Provenance.regions(provenance, group) do
      [{start, _stop} | _rest] -> start
      [] -> 0
    end
  end

  # Reverts a closure in one document pass and forgets its groups.
  @spec revert_groups(map(), MapSet.t()) :: {:ok, map()} | {:error, UndoPatch.apply_error()}
  defp revert_groups(walk, closure) do
    groups = MapSet.to_list(closure)
    history = walk.history
    yours = for group <- groups, Provenance.group_key(history.provenance, group) == nil, do: group

    with {:ok, document, first, provenance} <-
           Provenance.revert_all(history.provenance, groups, walk.document) do
      dropped = Enum.map(yours, &group_offset(provenance, &1))

      history =
        history
        |> forget_groups(groups)
        |> then(&%{&1 | provenance: Provenance.discard_all(provenance, groups)})

      {:ok,
       %{
         walk
         | history: history,
           document: document,
           groups: groups ++ walk.groups,
           dropped: dropped ++ walk.dropped,
           first: first || walk.first
       }}
    end
  end

  # Takes reverted groups out of Minga's steps, the untasked queue, and your undo stack.
  @spec forget_groups(t(), [Provenance.group_id()]) :: t()
  defp forget_groups(history, groups) do
    gone = MapSet.new(groups)

    {minga_gone, minga} =
      Enum.split_with(history.minga, fn {group, _key} -> MapSet.member?(gone, group) end)

    remaining_keys = MapSet.new(minga, &elem(&1, 1))

    steps =
      Map.filter(history.steps, fn {key, group} ->
        not MapSet.member?(gone, group) or MapSet.member?(remaining_keys, key)
      end)

    untasked = :queue.filter(&(not MapSet.member?(gone, &1)), history.untasked)
    entries = Enum.reject(history.undo_entries, &MapSet.member?(gone, &1.group))
    live_tasks = MapSet.new(minga, fn {_group, key} -> Author.author(key) end)

    live_tasks =
      if :queue.is_empty(untasked),
        do: live_tasks,
        else: MapSet.put(live_tasks, {:minga, :untasked})

    touched = for {_group, key} <- minga_gone, do: Author.author(key)

    %{
      history
      | minga: minga,
        steps: steps,
        untasked: untasked,
        untasked_size: :queue.len(untasked),
        undo_entries: entries,
        undo_size: length(entries),
        task_ticks:
          Map.filter(history.task_ticks, fn {task, _tick} -> MapSet.member?(live_tasks, task) end),
        task_started:
          Map.drop(history.task_started, Enum.reject(touched, &MapSet.member?(live_tasks, &1))),
        step_ticks: Map.drop(history.step_ticks, groups),
        merges: Enum.reduce(groups, history.merges, &unlink(&2, &1))
    }
  end

  @spec finish_walk(t(), map(), task(), non_neg_integer()) ::
          {:ok, Restore.t(), t(), reject_summary()}
          | {:blocked, {:overlaps, :you}, task(), hold()}
  defp finish_walk(_history, %{groups: []} = walk, task, _total),
    do: {:blocked, {:overlaps, :you}, task, held_at(walk.history, task)}

  defp finish_walk(history, walk, task, total) do
    remaining = walk.history |> task_groups(task) |> step_count(walk.history)
    every_step? = remaining == 0

    {version, tick, rest} =
      if every_step?, do: settle_tasks(walk.history, [task]), else: advance_tick(walk.history)

    rest = %{rest | tick: tick, task_run: nil}
    document = place_cursor(walk.document, walk.first, Document.cursor(walk.document))

    others =
      for group <- walk.groups,
          key = Provenance.group_key(history.provenance, group),
          key != nil,
          task_of(key) != task,
          uniq: true,
          do: task_of(key)

    summary = %{
      task: task,
      reverted:
        walk.groups |> Enum.filter(&(task_of_group(history, &1) == task)) |> step_count(history),
      total: total,
      tasks: others,
      groups: walk.groups,
      dropped: walk.dropped,
      held: if(every_step?, do: nil, else: held_at(rest, task)),
      rounds: walk.rounds
    }

    {:ok, Restore.new(version, document, :agent), rest, summary}
  end

  # The edit that holds the rest and where it is now, after everything this call reverted.
  @spec held_at(t(), task()) :: hold()
  defp held_at(history, task) do
    # Asked of the history after everything this call reverted: an edit that held an early step may have reverted
    # with a later one.
    history
    |> task_groups(task)
    |> Enum.sort(:desc)
    |> Enum.find_value({:yours, 0}, fn group ->
      closure =
        dependents(history.provenance, history.merges, [group], MapSet.new([group]), &no_group/1)

      case held_in(history.provenance, closure) do
        {:group, holding} -> {:yours, group_offset(history.provenance, holding)}
        {:offset, offset} -> {:permanent, offset}
        nil -> nil
      end
    end)
  end

  @spec advance_tick(t()) :: {:advance, Entry.tick(), t()}
  defp advance_tick(history) do
    {tick, history} = advance(history)
    {:advance, tick, history}
  end

  # The task's remaining groups: its steps' groups, or the untasked queue.
  @spec task_groups(t(), task()) :: [Provenance.group_id()]
  defp task_groups(history, task) do
    {steps, _rest} = take_task(history, task)
    Enum.map(steps, &elem(&1, 0))
  end

  @spec task_of_group(t(), Provenance.group_id()) :: task() | nil
  defp task_of_group(history, group) do
    case Provenance.group_key(history.provenance, group) do
      nil -> nil
      key -> task_of(key)
    end
  end

  # A step can hold several groups when other edits came between its own; steps count by key.
  @spec step_count([Provenance.group_id()], t()) :: non_neg_integer()
  defp step_count(groups, history) do
    groups |> Enum.map(&Provenance.group_key(history.provenance, &1)) |> Enum.uniq() |> length()
  end

  @doc """
  Reverts every remaining step of `task` and forgets those steps.

  Your text survives, including text you typed inside Minga's, and text the task replaced comes back unless someone deleted the replacement since. When a task that started after this one rewrote this task's text, the revert could not be exact: it changes nothing and returns `{:blocked, {:overlaps, minga_group}}` naming that task's step, which must be reverted first. Your edits never block a revert.

  When the task's steps are the newest changes and nothing else changed the document since they began, the restore returns the version from before them, so a buffer that was clean is clean again. Returns `{:ok, restore, history, reverted_steps}`, or `:empty` when the task has no remaining steps. When the steps' text does not fit `current_document`, returns `{:error, reason}` and the caller keeps its history and document unchanged.
  """
  @spec reject_task(t(), task(), version(), Document.t()) ::
          {:ok, Restore.t(), t(), pos_integer()}
          | :empty
          | blocked()
          | {:error, UndoPatch.apply_error()}
  def reject_task(%__MODULE__{} = history, task, _version, %Document{} = document) do
    case take_task(history, task) do
      {[], _rest} -> :empty
      {steps, rest} -> revert_task(history, rest, task, steps, document)
    end
  end

  @doc "Returns the remaining Minga steps of task `task_id` in this buffer, oldest first, with the byte ranges each touched."
  @spec minga_changes(t(), Author.id()) :: [minga_change()]
  def minga_changes(%__MODULE__{} = history, task_id) when is_binary(task_id) do
    # A step can hold several groups when other edits came between its own; it still reads as one step.
    steps =
      for {group, {:minga, ^task_id, _step} = key} <- Enum.reverse(history.minga),
          do: {key, group}

    keys = steps |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    by_key = Enum.group_by(steps, &elem(&1, 0), &elem(&1, 1))

    for key <- keys do
      regions =
        by_key
        |> Map.fetch!(key)
        |> Enum.flat_map(&Provenance.regions(history.provenance, &1))
        |> Enum.sort()

      {key, regions}
    end
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

  # The task whose step edited the document most recently.
  @spec revert_task(t(), t(), task(), [{Provenance.group_id(), minga_group()}], Document.t()) ::
          {:ok, Restore.t(), t(), pos_integer()} | blocked() | {:error, UndoPatch.apply_error()}
  defp revert_task(history, rest, task, steps, document) do
    with :ok <- unblocked_task(history, task, steps),
         {:ok, restore, rest, count, []} <-
           revert_steps_of(history, rest, [task], steps, [], document) do
      {:ok, restore, rest, count}
    end
  end

  # Reverts a task already known not to be blocked.
  @spec revert_steps_of(
          t(),
          t(),
          [task(), ...],
          [{Provenance.group_id(), minga_group()}],
          [Provenance.group_id()],
          Document.t()
        ) ::
          {:ok, Restore.t(), t(), pos_integer(), [non_neg_integer()]}
          | {:error, UndoPatch.apply_error()}
  defp revert_steps_of(history, rest, tasks, steps, yours, document) do
    groups = Enum.map(steps, &elem(&1, 0)) ++ yours

    with {:ok, reverted, first, provenance} <-
           Provenance.revert_all(history.provenance, groups, document) do
      # Where your dropped edits were, located in the reverted document before they are forgotten.
      dropped = Enum.map(yours, &group_offset(provenance, &1))
      provenance = Provenance.discard_all(provenance, groups)
      {version, tick, rest} = settle_tasks(rest, tasks)

      rest = %{
        rest
        | provenance: provenance,
          tick: tick,
          task_run: nil,
          task_ticks: Map.drop(rest.task_ticks, tasks),
          step_ticks: Map.drop(rest.step_ticks, Enum.map(steps, &elem(&1, 0))),
          merges: Enum.reduce(groups, rest.merges, &unlink(&2, &1))
      }

      document = place_cursor(reverted, first, Document.cursor(document))
      {:ok, Restore.new(version, document, :agent), rest, length(steps), dropped}
    end
  end

  # A task that started after this one and rewrote its text blocks the revert, as Minga's later steps block your undo.
  # Only newer tasks count, so tasks that rewrote each other can always be reverted newest first. A group that deleted
  # part of one of its replacements blocks it too, because the revert could not be exact.
  @spec unblocked_task(t(), task(), [{Provenance.group_id(), minga_group()}]) :: :ok | blocked()
  defp unblocked_task(history, task, steps) do
    starts = task_starts(history)
    groups = Enum.map(steps, &elem(&1, 0))

    case newer_blocker(history, groups, starts, task) do
      nil -> overlap_block(history, groups)
      minga_group -> {:blocked, {:overlaps, minga_group}}
    end
  end

  @spec newer_blocker(t(), [Provenance.group_id()], %{task() => Provenance.group_id()}, task()) ::
          minga_group() | nil
  defp newer_blocker(history, groups, starts, task) do
    start = Map.fetch!(starts, task)

    blocks? = fn
      :you, _key -> false
      _author, key -> task_of(key) != task and Map.get(starts, task_of(key), 0) > start
    end

    Provenance.blocker_among(history.provenance, groups, blocks?)
  end

  @spec overlap_block(t(), [Provenance.group_id()]) :: :ok | blocked()
  defp overlap_block(history, groups) do
    case Provenance.overlaps_among(history.provenance, groups) do
      [] -> :ok
      [{key, _offset} | _more] -> {:blocked, {:overlaps, key}}
    end
  end

  # The oldest remaining group of each task, which orders tasks by when they started.
  @spec task_starts(t()) :: %{task() => Provenance.group_id()}
  defp task_starts(history) do
    # Recorded when each task opened its first group, so merging its older steps away never makes it look newer.
    starts = history.task_started

    case :queue.peek(history.untasked) do
      {:value, group} -> Map.put(starts, {:minga, :untasked}, group)
      :empty -> starts
    end
  end

  # Returns the task's remaining groups, newest first, and the history without them.
  @spec take_task(t(), task()) :: {[{Provenance.group_id(), minga_group()}], t()}
  defp take_task(history, {:minga, :untasked}) do
    steps =
      history.untasked
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.map(&{&1, Provenance.group_key(history.provenance, &1)})

    {steps, %{history | untasked: :queue.new(), untasked_size: 0}}
  end

  defp take_task(history, task) do
    {steps, others} =
      Enum.split_with(history.minga, fn {_group, key} -> Author.author(key) == task end)

    {steps,
     %{
       history
       | minga: others,
         steps: Map.drop(history.steps, Enum.map(steps, &elem(&1, 1))),
         task_started: Map.delete(history.task_started, task)
     }}
  end

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
      | provenance: replay(history, history.provenance, top.group, patches),
        undo_entries: [%{top | tick_from: tick} | rest],
        tick: tick,
        last_recorded_at: at
    }
  end

  # A task's step continues the newest stretch of its steps when nothing else changed the document since.
  # Otherwise it starts a new stretch at the current version and tick.
  @spec extend_task_run(t(), task(), version()) :: task_run()
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
      fresh: not has_steps?(history, task)
    }
  end

  @spec has_steps?(t(), task()) :: boolean()
  defp has_steps?(history, {:minga, :untasked}), do: history.untasked_size > 0

  defp has_steps?(history, task),
    do: Enum.any?(history.minga, fn {_group, key} -> Author.author(key) == task end)

  # Agent edits without a task keep their last 1000 groups, like your stack.
  # An older one becomes permanent unattributed text, and a revert can no longer return to the version before it.
  @spec cap_untasked(t()) :: t()
  defp cap_untasked(%__MODULE__{untasked_size: size} = history) when size <= @max_entries,
    do: history

  defp cap_untasked(history) do
    {{:value, oldest}, untasked} = :queue.out(history.untasked)
    history = release_blocked(history, oldest)

    task_run =
      case history.task_run do
        %{task: {:minga, :untasked}} = run -> %{run | fresh: false}
        run -> run
      end

    %{
      history
      | provenance: Provenance.discard(history.provenance, oldest),
        untasked: untasked,
        untasked_size: history.untasked_size - 1,
        task_run: task_run
    }
  end

  # Before an untasked group becomes permanent, your groups it blocks leave your stacks.
  # Its tombstones are about to be dropped, and flipping such a group would then rebuild text that never existed.
  # Undo or redo would have stopped at that group anyway, so the stack ends there.
  @spec release_blocked(t(), Provenance.group_id()) :: t()
  defp release_blocked(history, group) do
    case Provenance.blocked_groups(history.provenance, group) do
      [] ->
        history

      blocked ->
        blocked = MapSet.new(blocked)
        {undo_entries, dropped_undo} = cut_at_blocked(history.undo_entries, blocked)
        {redo_entries, dropped_redo} = cut_at_blocked(history.redo_entries, blocked)

        provenance =
          Enum.reduce(dropped_undo ++ dropped_redo, history.provenance, fn entry, acc ->
            Provenance.discard(acc, entry.group)
          end)

        %{
          history
          | provenance: provenance,
            undo_entries: undo_entries,
            undo_size: length(undo_entries),
            redo_entries: redo_entries
        }
    end
  end

  # Keeps the entries above the newest blocked one and returns the rest, newest first.
  @spec cut_at_blocked([Entry.t()], MapSet.t(Provenance.group_id())) :: {[Entry.t()], [Entry.t()]}
  defp cut_at_blocked(entries, blocked),
    do: Enum.split_while(entries, &(not MapSet.member?(blocked, &1.group)))

  # A task reverted right after its only stretch of steps returns to the version and tick before that stretch.
  # A buffer that was clean is then clean again.
  @spec settle_tasks(t(), [task(), ...]) :: {version() | :advance, Entry.tick(), t()}
  defp settle_tasks(
         %__MODULE__{task_run: %{task: task, tick_after: tick, fresh: true} = run, tick: tick} =
           history,
         [task]
       ),
       do: {run.version, run.tick_before, history}

  defp settle_tasks(history, _tasks) do
    {tick, history} = advance(history)
    {:advance, tick, history}
  end

  # A Minga step reuses its group; an agent edit without a task always opens one.
  @spec minga_group(t(), Author.key() | :agent) :: {Provenance.group_id(), t()}
  defp minga_group(history, :agent), do: open_minga_group(history, {:minga, :untasked}, :agent)

  # A step's group takes a new edit only when nothing else changed the document since that step's last edit, as your
  # coalescing does; otherwise the step continues in a new group under the same key. A group's edits are then
  # consecutive changes, so every dependency between groups points from an older group to a newer one.
  defp minga_group(history, key) when Author.is_key(key) do
    if resumable?(history, Map.get(history.steps, key)),
      do: {Map.fetch!(history.steps, key), history},
      else: open_minga_group(history, Author.author(key), key)
  end

  # Nothing changed the document since the group's last edit, and no group was opened since (an undo can bring the
  # document back to the step's own last state).
  @spec resumable?(t(), Provenance.group_id() | nil) :: boolean()
  defp resumable?(_history, nil), do: false

  defp resumable?(history, group) do
    Map.get(history.step_ticks, group) == history.tick and
      Provenance.newest_group?(history.provenance, group)
  end

  @spec open_minga_group(t(), Provenance.author(), Author.key() | :agent) ::
          {Provenance.group_id(), t()}
  defp open_minga_group(history, author, :agent) do
    key = {:untasked, history.next_untasked}
    {group, provenance} = Provenance.open_group(history.provenance, author, key)

    {group,
     %{
       history
       | provenance: provenance,
         untasked: :queue.in(group, history.untasked),
         untasked_size: history.untasked_size + 1,
         next_untasked: history.next_untasked + 1
     }}
  end

  defp open_minga_group(history, author, key) do
    {group, provenance} = Provenance.open_group(history.provenance, author, key)

    {group,
     %{
       history
       | provenance: provenance,
         minga: [{group, key} | history.minga],
         steps: Map.put(history.steps, key, group),
         task_started: Map.put_new(history.task_started, author, group)
     }}
  end

  # Patches are in undo order, so the document saw them last to first.
  # Each patch is recorded as its smallest changes, from the last to the first so their offsets stay valid.
  @spec replay(t(), Provenance.t(), Provenance.group_id() | :untracked, [UndoPatch.t()]) ::
          Provenance.t()
  defp replay(%__MODULE__{recording: :coarse}, provenance, group, patches) do
    patches
    |> Enum.reverse()
    |> Enum.reduce(provenance, fn patch, acc ->
      {start, removed, inserted} = UndoPatch.change(patch)
      Provenance.edit(acc, group, start, removed, inserted)
    end)
  end

  defp replay(%__MODULE__{before: before}, provenance, group, patches) do
    writer =
      if group == :untracked, do: :unattributed, else: Provenance.group_author(provenance, group)

    # The document before the change describes only the first patch applied, which is the only one when there is one.
    context = if match?([_], patches), do: before

    patches
    |> Enum.reverse()
    |> Enum.reduce(provenance, fn patch, acc ->
      changes =
        acc |> anchored_changes(writer, patch) |> slide_deletions(patch, acc, writer, context)

      Provenance.edit_all(acc, group, changes)
    end)
  end

  # A pure deletion inside a run of identical bytes gives the same text wherever it sits in that run; each one takes
  # the place that covers the most bytes another author wrote, so the writer consumes the other author's copy and a
  # reject or an undo can never bring back a byte where it was not. A deletion stays between its neighbouring changes.
  # Bytes inside the patch come from its old text; past its edges, only a single-patch recording knows the document.
  @spec slide_deletions(
          [change()],
          UndoPatch.t(),
          Provenance.t(),
          Provenance.author(),
          Document.t() | nil
        ) ::
          [change()]
  defp slide_deletions(changes, patch, provenance, writer, context) do
    {start, old, _new} = UndoPatch.change(patch)
    old_end = start + byte_size(old)

    byte = fn offset ->
      cond do
        offset >= start and offset < old_end -> :binary.at(old, offset - start)
        context != nil -> Document.byte_at(context, offset)
      end
    end

    {low, high} = if context, do: {0, Document.content_byte_size(context)}, else: {start, old_end}
    # Where the text ends, when the whole document is known.
    text_end = if context, do: high
    tuple = List.to_tuple(changes)

    changes
    |> Enum.with_index()
    |> Enum.map(fn
      {{at, removed, ""} = change, index} when removed != "" ->
        lower = if index > 0, do: change_end(elem(tuple, index - 1)), else: low

        upper =
          if index + 1 < tuple_size(tuple), do: change_start(elem(tuple, index + 1)), else: high

        slide_deletion(
          change,
          {at, byte_size(removed)},
          {lower, upper},
          {byte, text_end},
          {provenance, writer}
        )

      {change, _index} ->
        change
    end)
  end

  # Where a neighbour leaves room: a deletion may touch the end of a replacement, never share a place with an insertion.
  @spec change_end(change()) :: non_neg_integer()
  defp change_end({at, "", _inserted}), do: at + 1
  defp change_end({at, removed, _inserted}), do: at + byte_size(removed)

  @spec change_start(change()) :: non_neg_integer()
  defp change_start({at, "", _inserted}), do: at - 1
  defp change_start({at, _removed, _inserted}), do: at

  @spec slide_deletion(
          change(),
          {non_neg_integer(), pos_integer()},
          {integer(), integer()},
          {(non_neg_integer() -> byte()), non_neg_integer() | nil},
          {Provenance.t(), Provenance.author()}
        ) :: change()
  defp slide_deletion(
         change,
         {at, length},
         {lower, upper},
         {byte, text_end},
         {provenance, writer}
       ) do
    lowest = slide_on(at, length, -1, &(&1 > lower and byte.(&1 - 1) == byte.(&1 + length - 1)))
    highest = slide_on(at, length, 1, &(&1 + length < upper and byte.(&1) == byte.(&1 + length)))

    if lowest == highest do
      change
    else
      foreign? = &(&1 != writer and &1 != :unattributed)
      spans = Provenance.spans(provenance, lowest, highest + length)
      covered = &foreign_bytes(spans, &1, length, foreign?)
      # A deletion moves only to a place where both its ends are grapheme cluster boundaries.
      cuts = cluster_boundaries({byte, text_end}, lowest, highest + length)

      candidates =
        for place <- lowest..highest,
            is_map_key(cuts, place) and is_map_key(cuts, place + length),
            do: place

      best = Enum.max_by([at | candidates], covered)

      if covered.(best) > covered.(at), do: {best, bytes_at(byte, best, length), ""}, else: change
    end
  end

  # How far a slide looks for the line breaks that bound its window. A line break always ends a grapheme cluster, so
  # the text between two of them segments the same as the whole document.
  @cluster_window 1_024

  # The grapheme cluster boundaries (UAX #29, as `String.graphemes/1` finds them) from `from` to `to`, read in a window
  # that starts after a line break (or at the start of the text) and ends at a line break (or the end of the text).
  # Without such bounds within `@cluster_window` bytes, or on text that is not valid UTF-8, there are none, so the
  # deletion stays where the patch put it. The cost is the window's length.
  @spec cluster_boundaries(
          {(non_neg_integer() -> byte() | nil), non_neg_integer() | nil},
          non_neg_integer(),
          non_neg_integer()
        ) :: %{non_neg_integer() => true}
  defp cluster_boundaries({byte, text_end}, from, to) do
    with {:ok, first} <- window_start(byte, from, from),
         {:ok, last} <- window_end({byte, text_end}, to, to),
         window = for(offset <- first..(last - 1)//1, into: <<>>, do: <<byte.(offset)>>),
         :ok <- valid_text(window) do
      window
      |> String.graphemes()
      |> Enum.scan(first, &(byte_size(&1) + &2))
      |> Map.new(&{&1, true})
      |> Map.put(first, true)
    else
      :none -> %{}
    end
  end

  @spec valid_text(binary()) :: :ok | :none
  defp valid_text(text), do: if(String.valid?(text), do: :ok, else: :none)

  # The offset just after the nearest line break at or before `offset`, or 0.
  @spec window_start((non_neg_integer() -> byte() | nil), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :none
  defp window_start(_byte, 0, _from), do: {:ok, 0}
  defp window_start(_byte, offset, from) when from - offset > @cluster_window, do: :none

  defp window_start(byte, offset, from) do
    case safe_byte(byte, offset - 1) do
      ?\n -> {:ok, offset}
      nil -> :none
      _byte -> window_start(byte, offset - 1, from)
    end
  end

  # The offset just after the nearest line break at or after `offset`, or the end of the text when it is known.
  @spec window_end(
          {(non_neg_integer() -> byte() | nil), non_neg_integer() | nil},
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, non_neg_integer()} | :none
  defp window_end(_text, offset, to) when offset - to > @cluster_window, do: :none
  defp window_end({_byte, text_end}, text_end, _to), do: {:ok, text_end}

  defp window_end({byte, _text_end} = text, offset, to) do
    case safe_byte(byte, offset) do
      ?\n -> {:ok, offset + 1}
      nil -> :none
      _byte -> window_end(text, offset + 1, to)
    end
  end

  @spec safe_byte((non_neg_integer() -> byte() | nil), non_neg_integer()) :: byte() | nil
  defp safe_byte(byte, offset) do
    byte.(offset)
  rescue
    _out_of_range -> nil
  end

  @spec bytes_at((non_neg_integer() -> byte()), non_neg_integer(), pos_integer()) :: binary()
  defp bytes_at(byte, from, length),
    do: for(offset <- from..(from + length - 1), into: <<>>, do: <<byte.(offset)>>)

  @spec slide_on(non_neg_integer(), pos_integer(), -1 | 1, (non_neg_integer() -> boolean())) ::
          non_neg_integer()
  defp slide_on(from, length, step, can_move?) do
    if can_move?.(from), do: slide_on(from + step, length, step, can_move?), else: from
  end

  # Another author's text survives only where an alignment proves it unchanged: prefix and suffix trims, the word
  # comparison's equal segments, and lines unique on both sides. Next to another author's text the word comparison
  # always runs. Text no alignment proves unchanged is part of the change, which can credit unchanged text inside a
  # long unpaired span to the writer; exact text and exact rejects come first. See `slide_deletion/5` for a
  # deletion at the edge of a run of identical bytes.
  @spec anchored_changes(Provenance.t(), Provenance.author(), UndoPatch.t()) :: [change()]
  defp anchored_changes(provenance, writer, patch) do
    {start, old, new} = UndoPatch.change(patch)
    foreign? = &(&1 != writer and &1 != :unattributed)
    spans = Provenance.spans(provenance, start, start + byte_size(old))

    if Enum.any?(spans, &foreign?.(elem(&1, 2))) do
      UndoPatch.segment_changes(start, old, new, true)
    else
      UndoPatch.precise_changes(patch)
    end
  end

  @spec foreign_bytes(
          [Provenance.span()],
          non_neg_integer(),
          pos_integer(),
          (Provenance.author() -> boolean())
        ) ::
          non_neg_integer()
  defp foreign_bytes(spans, from, length, foreign?) do
    to = from + length

    for {span_from, span_to, author, _key} <- spans, foreign?.(author), reduce: 0 do
      bytes -> bytes + max(0, min(to, span_to) - max(from, span_from))
    end
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

  # When nothing changed the document since the entry's state, the flip returns exactly to that state.
  # Its version, cursor and tick then come back. Otherwise the document is new.
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

  # Puts the cursor at the first change, or at `fallback` when nothing changed.
  @spec place_cursor(Document.t(), non_neg_integer() | nil, Document.position()) :: Document.t()
  defp place_cursor(document, nil, fallback), do: Document.move_to(document, fallback)

  defp place_cursor(document, offset, _fallback),
    do: Document.move_to(document, Position.from_point(document, offset))

  @spec task_of(Author.key() | minga_group() | :agent) :: task()
  defp task_of(:agent), do: {:minga, :untasked}
  defp task_of({:untasked, _n}), do: {:minga, :untasked}
  defp task_of(key), do: Author.author(key)
end
