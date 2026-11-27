defmodule Minga.Buffer.UndoHistory do
  @moduledoc """
  Undo and redo history for a buffer, separate for you and for Minga, over one record of who wrote each byte.

  Every change to the document is recorded in a `Minga.Buffer.Provenance` value, which knows the author of every byte and keeps deleted text as tombstones. This module decides which history group each change belongs to:

  * **Yours.** Edits from you (`:user`), from a language server or formatter you invoked (`:lsp`), and from swap recovery (`:recovery`) form your undo stack. Rapid edits from the same source coalesce into one group within `coalesce_ms/0`. The stack keeps your last 1000 groups; an older group becomes permanent text that keeps its author.
  * **Minga's.** Each step of a Minga task (an author key, `Minga.Buffer.Author.key/0`) is its own group, never coalesced with another step or task and never evicted. An agent edit without a task (`:agent`) is a group of its own, written by `{:minga, :untasked}` and named `{:untasked, n}`; the last 1000 such groups stay revertable, and an older one becomes permanent text that keeps that author. Before it does, any undo or redo step of yours it blocks leaves your stacks, with everything below it, so no flip can rebuild text that never existed. Minga's groups never enter your stacks.

  `undo/3` and `redo/3` move only your groups. They find a group's text by its runs, not by byte offsets, so they stay exact when Minga edited above, below, or inside your text since. When flipping your group would change text that a later Minga step rewrote, they change nothing and return `{:blocked, {:overlaps, minga_group}}`. Minga's edits never clear your redo stack.

  Who wrote each byte follows the text only where an alignment proves it unchanged: line and word trims, the word comparison's equal segments, and lines unique on both sides. Anything else is part of the change, so unchanged text inside one long line past the word budget, or inside an unpaired span with no unique line, is credited to the writer; exact text and exact rejects come first. A single deletion inside a run of identical text takes another author's copy first. The slider's unit is the grapheme cluster as Unicode defines it (UAX #29, as `String.graphemes/1` segments): both ends of the deletion stay cluster boundaries, so a flag, a conjoining jamo syllable, a ZWJ sequence or a letter with its marks is never split. It segments a window bounded by line breaks within a fixed distance, so its cost stays linear; without such bounds the deletion stays where the patch put it. The changes the history records (trims, word tokens, anchored spans and one-pass batches) also start and end on cluster boundaries, and every recorded run boundary is a cut between code points, so a revert never leaves part of a cluster that never existed.

  A step's group takes a new edit only when nothing changed the document and no group was opened since its last edit; otherwise the step continues in a new group under the same key. Every dependency between groups then points from an older group to a newer one: a later group that rewrote a group's text, or a group that edited inside a Minga group's replacement (text a step wrote in place of other text).

  `reject_task/4` reverts all of a task's steps or nothing. A newer task that rewrote its text or a later edit inside one of its replacements can refuse the operation. `undo_agent_session/3` instead selects a jointly exact set. A user group can leave the undo stack only if none of its text is visible and reverting it with the selected steps does not revive text the user deleted. When several otherwise safe choices conflict in combination, all steps that require a contributor stay. Steps independent of the conflict can still revert.

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
  alias Minga.Buffer.KeptReview.{Ledger, Source}
  alias Minga.Buffer.Position
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.UndoHistory.Entry
  alias Minga.Buffer.UndoHistory.RejectSelection
  alias Minga.Buffer.UndoHistory.Restore
  alias Minga.Buffer.UndoPatch
  alias Minga.Git.ReviewIdentity

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
  What one `undo_agent_session/3` call reverted; see there. `rounds` counts the walks the press needed before its set stopped changing: one, plus one for each walk that found a step it counted as reverting held. `held_by_round` lists the task's steps held after each walk; each list contains the one before, and none of them is reverted.
  """
  @type reject_summary :: %{
          task: task(),
          reverted: non_neg_integer(),
          total: non_neg_integer(),
          tasks: [task()],
          groups: [Provenance.group_id()],
          dropped: [non_neg_integer()],
          held: hold() | nil,
          rounds: pos_integer(),
          held_by_round: [[Provenance.group_id()]]
        }

  @typedoc "A Minga step and the byte ranges it touched, as `Minga.Buffer.Provenance.regions/2` reports them."
  @type minga_change :: {Author.key(), [Provenance.byte_range()]}

  @typedoc "All pending groups that must accept the same review decision."
  @opaque review_unit :: nonempty_list(Provenance.group_id())

  @typedoc "A spatially contiguous part of one pending review unit, keyed by its oldest member."
  @type review_region :: {Provenance.group_id(), non_neg_integer(), non_neg_integer()}

  @typedoc "A prepared set of review units, valid only in the history revision that offered it."
  @opaque review_target :: {Entry.tick(), nonempty_list(task_review_unit())}

  @typedoc "An unapplied whole review unit, separate from the user's redo stack."
  @opaque rejected_unit :: {:rejected, rejection_id()}

  @type review_selection ::
          :latest
          | {:task, task()}
          | {:step, minga_group()}
          | {:at_byte, non_neg_integer()}
          | {:at_byte, non_neg_integer(), pos_integer()}
          | {:byte_range, non_neg_integer(), non_neg_integer()}
  @type review_scope :: task() | :multiple_tasks
  @typep task_review_unit :: {task(), review_unit()}
  @type review_error :: UndoPatch.apply_error() | :stale_review | :inconsistent_review
  @typep rejection_id :: {<<_::128>>, Entry.tick(), Provenance.group_id()}
  @typep parked_unit :: {task(), review_unit(), Provenance.restore_proof()}
  @typep rejected_units :: %{rejection_id() => parked_unit()}
  @type saved_checkpoint :: {<<_::256>>, binary()}
  @type saved_observation :: :unproven | {ReviewIdentity.t(), binary()}
  @typep saved_origins :: %{Provenance.group_id() => MapSet.t(Provenance.group_id())}

  @typep pending_groups :: %{Provenance.group_id() => minga_group()}
  @typep groups_by_step :: %{minga_group() => MapSet.t(Provenance.group_id())}
  @typep groups_by_task :: %{task() => MapSet.t(Provenance.group_id())}

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
            pending_groups: %{},
            groups_by_step: %{},
            groups_by_task: %{},
            rejected: %{},
            review_seen: false,
            saved_ceiling: 1,
            saved_origins: %{},
            kept_review: nil,
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
            absorbed_steps: %{},
            inline_merged: []

  @opaque t :: %__MODULE__{
            provenance: Provenance.t(),
            undo_entries: [Entry.t()],
            undo_size: non_neg_integer(),
            redo_entries: [Entry.t()],
            pending_groups: pending_groups(),
            groups_by_step: groups_by_step(),
            groups_by_task: groups_by_task(),
            rejected: rejected_units(),
            review_seen: boolean(),
            saved_ceiling: pos_integer(),
            saved_origins: saved_origins(),
            kept_review: Ledger.t(),
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
            absorbed_steps: absorbed_steps(),
            inline_merged: [{minga_group(), minga_group()}]
          }

  @doc """
  Creates an empty history for `document`, whose text all predates tracking.

  Options:

  * `:run_budget` - how many runs, tombstones included, the history keeps before `compaction_wanted?/1` asks for draft compaction (default #{@run_budget}). See `compact_slice/2`.
  * `:recording` - `:precise` (the default) records each edit as its smallest changes. `:coarse` records each patch as one change, as a fallback would; tests use it to prove that a revert stays exact or is refused whatever the recording granularity.
  * `:origin_scope` - the buffer incarnation for new authored edit origins. Restored origins keep their original scope.
  """
  @spec new(Document.t(), [
          {:recording, recording()}
          | {:run_budget, pos_integer()}
          | {:origin_scope, non_neg_integer()}
        ]) :: t()
  def new(%Document{} = document \\ Document.new(""), opts \\ []) when is_list(opts) do
    %__MODULE__{
      provenance:
        Provenance.new(Document.content_byte_size(document), Keyword.get(opts, :origin_scope, 0)),
      kept_review: Ledger.new(),
      untasked: :queue.new(),
      recording: Keyword.get(opts, :recording, :precise),
      run_budget: Keyword.get(opts, :run_budget, @run_budget)
    }
  end

  @doc "Forgets all history and authorship and starts again for `document`, keeping the history's options."
  @spec reset(t(), Document.t()) :: t()
  def reset(%__MODULE__{} = history, %Document{} = document) do
    reset = new(document, recording: history.recording, run_budget: history.run_budget)
    provenance = Provenance.inherit_origin_scope(reset.provenance, history.provenance)
    %{reset | provenance: provenance, next_tick: history.next_tick + 1}
  end

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
    groups =
      Enum.map(history.undo_entries, & &1.group) ++ Enum.map(history.redo_entries, & &1.group)

    patches = UndoPatch.changes(old_document, new_document)

    provenance =
      Provenance.replace_base(history.provenance, groups, fn provenance ->
        replay(%{history | before: nil}, provenance, :untracked, patches)
      end)

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

  @doc "Whether this buffer has review history or permanent Minga authorship to checkpoint."
  @spec review_history?(t()) :: boolean()
  def review_history?(%__MODULE__{review_seen: seen}), do: seen

  @doc "Starts the saved namespace and captures the review checkpoint for the exact saved bytes."
  @spec checkpoint(t(), binary()) :: {t(), saved_checkpoint()}
  def checkpoint(%__MODULE__{} = history, content) when is_binary(content) do
    digest = :crypto.hash(:sha256, content)

    history = %{
      history
      | saved_ceiling: Provenance.group_ceiling(history.provenance),
        saved_origins: %{},
        kept_review: Ledger.save(history.kept_review, digest, content, history.provenance)
    }

    {history, {digest, encode_snapshot(history, digest, byte_size(content))}}
  end

  @doc """
  Encodes the review state for these exact document bytes.

  User undo and redo end at a reopen. Their edits retain their authorship and still constrain an exact review decision. The snapshot retains pending units, parked Rejects and the history identifiers they share, but no editor state or undo patches.
  """
  @spec snapshot(t(), binary()) :: binary()
  def snapshot(%__MODULE__{} = history, content) when is_binary(content),
    do: encode_snapshot(history, :crypto.hash(:sha256, content), byte_size(content))

  @spec encode_snapshot(t(), <<_::256>>, non_neg_integer()) :: binary()
  defp encode_snapshot(history, digest, size) do
    users = Enum.map(history.undo_entries ++ history.redo_entries, & &1.group)
    provenance = Provenance.discard_all(history.provenance, users)

    :erlang.term_to_binary({
      :review_history_v1,
      digest,
      size,
      %{
        pending: saved_task_groups(history.pending_groups),
        untasked: :queue.to_list(history.untasked),
        rejected: history.rejected,
        merges: encode_review_index(history.merges),
        absorbed_steps: encode_review_index(history.absorbed_steps),
        task_started: history.task_started,
        task_ticks: history.task_ticks,
        next_tick: history.next_tick,
        next_untasked: history.next_untasked,
        saved_ceiling: history.saved_ceiling,
        saved_origins:
          Map.new(history.saved_origins, fn {id, origins} -> {id, MapSet.to_list(origins)} end),
        kept_review: Ledger.snapshot(history.kept_review),
        provenance: Provenance.snapshot(provenance)
      }
    })
  end

  @spec saved_task_groups(pending_groups()) :: [Provenance.group_id()]
  defp saved_task_groups(pending) do
    pending
    |> Enum.reduce([], fn
      {_id, {:untasked, _sequence}}, groups -> groups
      {id, _key}, groups -> [id | groups]
    end)
    |> Enum.sort(:desc)
  end

  @spec encode_review_index(%{Provenance.group_id() => MapSet.t(value)}) ::
          %{Provenance.group_id() => [value]}
        when value: Provenance.group_id() | Author.key()
  defp encode_review_index(links) do
    Map.new(links, fn {id, neighbours} -> {id, MapSet.to_list(neighbours)} end)
  end

  @doc "Restores a review snapshot only for the exact content that produced it."
  @spec restore_snapshot(t(), binary(), binary()) :: {:ok, t()} | {:error, :invalid_history}
  def restore_snapshot(%__MODULE__{} = history, snapshot, content) when is_binary(content) do
    digest = :crypto.hash(:sha256, content)
    size = byte_size(content)

    case decode_snapshot(snapshot) do
      {:ok, ^digest, ^size, saved} ->
        with {:ok, restored} <- restore_review_snapshot(history, saved, size) do
          provenance = Provenance.inherit_origin_scope(restored.provenance, history.provenance)
          {:ok, %{restored | provenance: provenance}}
        end

      _no_match ->
        {:error, :invalid_history}
    end
  end

  @spec decode_snapshot(binary()) ::
          {:ok, <<_::256>>, non_neg_integer(), term()} | {:error, :invalid_history}
  defp decode_snapshot(<<131, type, _::binary>> = snapshot) when type != 80 do
    case :erlang.binary_to_term(snapshot, [:safe, :used]) do
      {{:review_history_v1, <<_::256>> = digest, size, saved}, used}
      when used == byte_size(snapshot) and is_integer(size) and size >= 0 ->
        {:ok, digest, size, saved}

      _invalid ->
        {:error, :invalid_history}
    end
  rescue
    ArgumentError -> {:error, :invalid_history}
  end

  defp decode_snapshot(_invalid), do: {:error, :invalid_history}

  @typep review_membership :: %{
           Provenance.group_id() => {:pending, task()} | {:parked, rejection_id()}
         }

  @spec restore_review_snapshot(t(), term(), non_neg_integer()) ::
          {:ok, t()} | {:error, :invalid_history}
  defp restore_review_snapshot(
         history,
         %{
           pending: pending,
           untasked: untasked,
           rejected: rejected,
           merges: merges,
           absorbed_steps: absorbed,
           task_started: starts,
           task_ticks: ticks,
           next_tick: revision,
           next_untasked: next_untasked,
           saved_ceiling: ceiling,
           saved_origins: origins,
           provenance: saved_provenance
         } = snapshot,
         size
       )
       when is_list(pending) and is_list(untasked) and is_map(rejected) and is_map(merges) and
              is_map(absorbed) and is_map(starts) and is_map(ticks) and is_integer(revision) and
              revision > 0 and is_integer(next_untasked) and next_untasked > 0 do
    with {:ok, provenance} <- Provenance.restore_snapshot(saved_provenance, size),
         {:ok, members, steps} <-
           restore_membership(provenance, pending, untasked, rejected, revision, next_untasked),
         :ok <- validate_task_history(steps, untasked, ticks, starts, revision),
         {:ok, merges} <- restore_review_links(merges, members),
         {:ok, absorbed} <- restore_absorbed_steps(absorbed, members, provenance),
         :ok <- validate_parked_steps(rejected, provenance, {merges, absorbed}),
         {:ok, origins} <- restore_saved_origins(ceiling, origins, members, provenance),
         {:ok, kept_review} <- Ledger.restore(Map.get(snapshot, :kept_review)) do
      next_tick = max(history.next_tick, revision) + 1

      restored = %__MODULE__{
        provenance: provenance,
        rejected: rejected,
        merges: merges,
        absorbed_steps: absorbed,
        review_seen: true,
        saved_ceiling: ceiling,
        saved_origins: origins,
        kept_review: kept_review,
        steps: steps |> Enum.reverse() |> Map.new(fn {id, key} -> {key, id} end),
        untasked: :queue.from_list(untasked),
        untasked_size: length(untasked),
        next_untasked: next_untasked,
        task_started: starts,
        task_ticks: ticks,
        tick: next_tick - 1,
        next_tick: next_tick,
        run_budget: history.run_budget,
        recording: history.recording
      }

      restored = Enum.reduce(steps, restored, fn {id, key}, acc -> add_pending(acc, id, key) end)
      {:ok, add_pending_groups(restored, untasked)}
    else
      {:error, _reason} -> {:error, :invalid_history}
    end
  rescue
    _invalid_payload in [ArgumentError, FunctionClauseError] -> {:error, :invalid_history}
  end

  defp restore_review_snapshot(_history, _saved, _size), do: {:error, :invalid_history}

  @spec restore_saved_origins(term(), term(), review_membership(), Provenance.t()) ::
          {:ok, saved_origins()} | {:error, :invalid_history}
  defp restore_saved_origins(ceiling, origins, members, provenance)
       when is_integer(ceiling) and ceiling > 0 and is_map(origins) do
    with :ok <-
           valid_history(
             ceiling <= Provenance.group_ceiling(provenance) and
               Enum.all?(origins, fn {id, refs} ->
                 is_map_key(members, id) and is_list(refs) and refs != [] and
                   Enum.all?(refs, &(is_integer(&1) and &1 > 0 and &1 < ceiling and &1 < id))
               end)
           ) do
      {:ok, Map.new(origins, fn {id, refs} -> {id, MapSet.new(refs)} end)}
    end
  end

  defp restore_saved_origins(_ceiling, _origins, _members, _provenance),
    do: {:error, :invalid_history}

  @spec restore_membership(
          Provenance.t(),
          [Provenance.group_id()],
          [Provenance.group_id()],
          rejected_units(),
          Entry.tick(),
          pos_integer()
        ) ::
          {:ok, review_membership(), [{Provenance.group_id(), Author.key()}]}
          | {:error, :invalid_history}
  defp restore_membership(prov, pending, untasked, rejected, revision, next_untasked) do
    available = pending ++ untasked

    with :ok <- validate_pending_order(pending, untasked),
         {:ok, members} <- index_saved_members(prov, available, %{}, :pending, next_untasked),
         {:ok, members} <- index_parked_members(prov, rejected, members, revision, next_untasked),
         :ok <- valid_history(map_size(members) == Provenance.group_count(prov)),
         :ok <-
           valid_history(
             Enum.all?(pending, &Author.is_key(Provenance.group_key(prov, &1))) and
               Enum.all?(untasked, &(Provenance.group_author(prov, &1) == {:minga, :untasked}))
           ) do
      {:ok, members, Enum.map(pending, &{&1, Provenance.group_key(prov, &1)})}
    end
  end

  @spec validate_pending_order([Provenance.group_id()], [Provenance.group_id()]) ::
          :ok | {:error, :invalid_history}
  defp validate_pending_order(pending, untasked) do
    valid_history(
      length(untasked) <= @max_entries and ordered?(pending, :descending) and
        ordered?(untasked, :ascending)
    )
  end

  @spec ordered?([term()], :ascending | :descending) :: boolean()
  defp ordered?([a, b | rest], :ascending), do: a < b and ordered?([b | rest], :ascending)
  defp ordered?([a, b | rest], :descending), do: a > b and ordered?([b | rest], :descending)
  defp ordered?(_single_or_empty, _direction), do: true

  @spec index_saved_members(
          Provenance.t(),
          [Provenance.group_id()],
          review_membership(),
          :pending | {:parked, rejection_id(), task()},
          pos_integer()
        ) :: {:ok, review_membership()} | {:error, :invalid_history}
  defp index_saved_members(prov, ids, members, kind, next_untasked) do
    Enum.reduce_while(ids, {:ok, members}, fn id, {:ok, acc} ->
      case saved_member(prov, id, acc, kind, next_untasked) do
        {:ok, member} -> {:cont, {:ok, Map.put(acc, id, member)}}
        :error -> {:halt, {:error, :invalid_history}}
      end
    end)
  end

  @spec saved_member(Provenance.t(), term(), review_membership(), term(), pos_integer()) ::
          {:ok, {:pending, task()} | {:parked, rejection_id()}} | :error
  defp saved_member(prov, id, members, kind, next) do
    if is_integer(id) and not is_map_key(members, id) and Provenance.group?(prov, id) and
         valid_untasked_key?(Provenance.group_key(prov, id), next) do
      member_state(kind, Provenance.group_author(prov, id), Provenance.applied?(prov, id))
    else
      :error
    end
  end

  @spec valid_untasked_key?(Provenance.group_key(), pos_integer()) :: boolean()
  defp valid_untasked_key?({:untasked, id}, next), do: id < next
  defp valid_untasked_key?(key, _next), do: Author.is_key(key)

  @spec member_state(
          :pending | {:parked, rejection_id(), task()},
          Provenance.author(),
          boolean()
        ) :: {:ok, {:pending, task()} | {:parked, rejection_id()}} | :error
  defp member_state(:pending, {:minga, _id} = task, true), do: {:ok, {:pending, task}}

  defp member_state({:parked, receipt, task}, task, false), do: {:ok, {:parked, receipt}}
  defp member_state(_kind, _task, _applied), do: :error

  @spec index_parked_members(
          Provenance.t(),
          rejected_units(),
          review_membership(),
          Entry.tick(),
          pos_integer()
        ) :: {:ok, review_membership()} | {:error, :invalid_history}
  defp index_parked_members(prov, rejected, members, revision, next_untasked) do
    Enum.reduce_while(rejected, {:ok, members}, fn
      {{<<_::128>>, tick, id} = receipt, {task, [id | _] = ids, {coverage, <<_::256>>}}},
      {:ok, acc}
      when is_integer(tick) and tick > 0 and tick < revision and is_list(ids) and
             is_integer(coverage) and coverage >= 0 ->
        case index_saved_members(prov, ids, acc, {:parked, receipt, task}, next_untasked) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, _members ->
        {:halt, {:error, :invalid_history}}
    end)
  end

  @typep parked_step_index :: %{
           optional(Entry.tick()) => <<_::128>>,
           optional({Entry.tick(), minga_group()}) => rejection_id()
         }

  @spec validate_parked_steps(rejected_units(), Provenance.t(), {merges(), absorbed_steps()}) ::
          :ok | {:error, :invalid_history}
  defp validate_parked_steps(rejected, provenance, {_merges, absorbed} = links) do
    result =
      Enum.reduce_while(rejected, {:ok, %{}}, fn {receipt, {_task, ids, _proof}}, {:ok, acc} ->
        with {:ok, acc} <- index_parked_nonce(acc, receipt),
             :ok <- validate_parked_unit(ids, provenance, links),
             {:ok, acc} <- index_parked_steps(provenance, absorbed, ids, receipt, acc) do
          {:cont, {:ok, acc}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, _index} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec index_parked_nonce(parked_step_index(), rejection_id()) ::
          {:ok, parked_step_index()} | {:error, :invalid_history}
  defp index_parked_nonce(index, {nonce, tick, _group}) do
    case index do
      %{^tick => ^nonce} -> {:ok, index}
      %{^tick => _other} -> {:error, :invalid_history}
      _new -> {:ok, Map.put(index, tick, nonce)}
    end
  end

  @spec validate_parked_unit(review_unit(), Provenance.t(), {merges(), absorbed_steps()}) ::
          :ok | {:error, :invalid_history}
  defp validate_parked_unit([_group], _provenance, _links), do: :ok

  defp validate_parked_unit([head | _] = groups, provenance, {_merges, absorbed} = links) do
    members = Map.new(groups, &{&1, Provenance.group_key(provenance, &1)})
    keys = Enum.reduce(members, %{}, &index_review_keys(&1, &2, absorbed))
    {_unit, remaining, _keys} = collect_review_unit([head], members, keys, links, [])
    valid_history(map_size(remaining) == 0)
  end

  @spec index_parked_steps(
          Provenance.t(),
          absorbed_steps(),
          review_unit(),
          rejection_id(),
          parked_step_index()
        ) :: {:ok, parked_step_index()} | {:error, :invalid_history}
  defp index_parked_steps(prov, absorbed, ids, {_nonce, tick, _} = receipt, steps) do
    ids
    |> Enum.flat_map(fn id ->
      [Provenance.group_key(prov, id) | Enum.to_list(Map.get(absorbed, id, []))]
    end)
    |> Enum.reduce_while({:ok, steps}, fn step, {:ok, acc} ->
      key = {tick, step}

      case acc do
        %{^key => ^receipt} -> {:cont, {:ok, acc}}
        %{^key => _different_unit} -> {:halt, {:error, :invalid_history}}
        _new_step -> {:cont, {:ok, Map.put(acc, key, receipt)}}
      end
    end)
  end

  @spec validate_task_history(
          [{Provenance.group_id(), Author.key()}],
          [Provenance.group_id()],
          %{task() => Entry.tick()},
          %{Author.t() => Provenance.group_id()},
          Entry.tick()
        ) :: :ok | {:error, :invalid_history}
  defp validate_task_history(steps, untasked, ticks, starts, revision) do
    oldest = Map.new(steps, fn {id, key} -> {Author.author(key), id} end)
    tasks = if untasked == [], do: oldest, else: Map.put(oldest, {:minga, :untasked}, nil)

    valid_history(
      map_size(ticks) == map_size(tasks) and map_size(starts) == map_size(oldest) and
        valid_task_ticks?(ticks, tasks, revision) and
        Enum.all?(starts, fn {task, start} ->
          case oldest do
            %{^task => group} -> is_integer(start) and start > 0 and start <= group
            _invalid -> false
          end
        end)
    )
  end

  @spec valid_task_ticks?(%{task() => Entry.tick()}, map(), Entry.tick()) :: boolean()
  defp valid_task_ticks?(ticks, tasks, revision) do
    Enum.all?(ticks, fn {task, tick} ->
      is_map_key(tasks, task) and is_integer(tick) and tick > 0 and tick < revision
    end)
  end

  @spec restore_review_links(map(), review_membership()) ::
          {:ok, merges()} | {:error, :invalid_history}
  defp restore_review_links(merges, members) do
    with :ok <-
           valid_history(
             Enum.all?(merges, fn {id, neighbours} ->
               is_map_key(members, id) and is_list(neighbours) and neighbours != [] and
                 Enum.all?(neighbours, &(&1 != id and Map.get(members, &1) == members[id]))
             end)
           ) do
      links = Map.new(merges, fn {id, neighbours} -> {id, MapSet.new(neighbours)} end)

      if symmetric_review_links?(links), do: {:ok, links}, else: {:error, :invalid_history}
    end
  end

  @spec symmetric_review_links?(merges()) :: boolean()
  defp symmetric_review_links?(links) do
    Enum.all?(links, fn {id, neighbours} ->
      Enum.all?(neighbours, &has_review_link?(links, &1, id))
    end)
  end

  @spec has_review_link?(merges(), Provenance.group_id(), Provenance.group_id()) :: boolean()
  defp has_review_link?(links, from, to) do
    case Map.fetch(links, from) do
      {:ok, neighbours} -> MapSet.member?(neighbours, to)
      :error -> false
    end
  end

  @spec restore_absorbed_steps(map(), review_membership(), Provenance.t()) ::
          {:ok, absorbed_steps()} | {:error, :invalid_history}
  defp restore_absorbed_steps(absorbed, members, provenance) do
    Enum.reduce_while(absorbed, {:ok, %{}}, fn {id, keys}, {:ok, acc} ->
      primary = Provenance.group_key(provenance, id)

      if is_map_key(members, id) and Author.is_key(primary) and is_list(keys) and keys != [] and
           Enum.all?(keys, &valid_absorbed_step?(&1, primary)) do
        {:cont, {:ok, Map.put(acc, id, MapSet.new(keys))}}
      else
        {:halt, {:error, :invalid_history}}
      end
    end)
  end

  @spec valid_absorbed_step?(term(), Author.key()) :: boolean()
  defp valid_absorbed_step?(key, primary) do
    Author.is_key(key) and key != primary and Author.author(key) == Author.author(primary)
  end

  @spec valid_history(boolean()) :: :ok | {:error, :invalid_history}
  defp valid_history(true), do: :ok
  defp valid_history(false), do: {:error, :invalid_history}

  @doc "Returns who wrote each byte of the document."
  @spec provenance(t()) :: Provenance.t()
  def provenance(%__MODULE__{provenance: provenance}), do: provenance

  @doc "Whether an ordinary user's edit left all distant authored ranges and unit identities intact."
  @spec local_user_review_edit?(t(), t()) :: boolean()
  def local_user_review_edit?(
        %__MODULE__{
          redo_entries: [],
          pending_groups: units,
          merges: merges,
          absorbed_steps: absorbed,
          undo_size: prior
        } = before,
        %__MODULE__{
          pending_groups: units,
          merges: merges,
          absorbed_steps: absorbed,
          undo_size: current
        } = after_edit
      ) do
    current == prior + 1 or (current == prior and same_newest_user_group?(before, after_edit))
  end

  def local_user_review_edit?(_before, _after_edit), do: false

  @spec same_newest_user_group?(t(), t()) :: boolean()
  defp same_newest_user_group?(
         %__MODULE__{undo_entries: [%Entry{group: group} | _]},
         %__MODULE__{undo_entries: [%Entry{group: group} | _]}
       ),
       do: true

  defp same_newest_user_group?(_before, _after_edit), do: false

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
    # Open against the existing frontier. No compaction can happen in the middle of replacing redo.
    {group, provenance} = Provenance.open_group(history.provenance, :you, nil)
    history = drop_redo(%{history | provenance: provenance})
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
      | provenance: replay(history, history.provenance, group, patches),
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
    history = if merged == [], do: history, else: invalidate_review(history)
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
          history = forget_empty_step(%{history | merges: merges}, old, new, provenance)
          compact_until(history, max_runs, examined + runs, [pair | merged], done?)
      end
    end
  end

  # An absorbed step still names the unit for exact review, even if its next group does not exist yet.
  # Legacy Reject and the edit coalescer keep their existing live-group rules.
  @spec forget_empty_step(t(), Provenance.group_id(), Provenance.group_id(), Provenance.t()) ::
          t()
  defp forget_empty_step(history, old, new, provenance) do
    if Provenance.group?(provenance, old) do
      %{history | provenance: provenance}
    else
      key = Map.fetch!(history.pending_groups, old)

      steps =
        case history.steps do
          %{^key => ^old} -> Map.delete(history.steps, key)
          _newer -> history.steps
        end

      new_key = Provenance.group_key(provenance, new)
      absorbed = transfer_review_keys(history.absorbed_steps, old, new, key, new_key)

      history = history |> remove_pending(old) |> remove_pending(new)

      %{
        history
        | provenance: provenance,
          steps: steps,
          absorbed_steps: absorbed,
          saved_origins: absorb_saved_origin(history, old, new),
          step_ticks: Map.delete(history.step_ticks, old)
      }
      |> add_pending(new, new_key)
    end
  end

  @typep absorbed_steps :: %{Provenance.group_id() => MapSet.t(Author.key())}

  @spec transfer_review_keys(
          absorbed_steps(),
          Provenance.group_id(),
          Provenance.group_id(),
          Author.key(),
          Author.key()
        ) :: absorbed_steps()
  defp transfer_review_keys(absorbed, old, new, old_key, new_key) do
    {keys, absorbed} = Map.pop(absorbed, old)

    if is_nil(keys) and old_key == new_key do
      absorbed
    else
      keys = (keys || MapSet.new()) |> MapSet.put(old_key) |> MapSet.delete(new_key)
      Map.update(absorbed, new, keys, &MapSet.union(&1, keys))
    end
  end

  @spec absorb_saved_origin(t(), Provenance.group_id(), Provenance.group_id()) :: saved_origins()
  defp absorb_saved_origin(history, old, new) do
    case Map.pop(history.saved_origins, old) do
      {nil, origins} when old >= history.saved_ceiling ->
        origins

      {depends, origins} ->
        refs = include_saved_id(depends || MapSet.new(), old, history.saved_ceiling)
        Map.update(origins, new, refs, &MapSet.union(&1, refs))
    end
  end

  @spec include_saved_id(MapSet.t(Provenance.group_id()), Provenance.group_id(), pos_integer()) ::
          MapSet.t(Provenance.group_id())
  defp include_saved_id(ids, id, ceiling) when id < ceiling, do: MapSet.put(ids, id)
  defp include_saved_id(ids, _id, _ceiling), do: ids

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

  A step reverts together with any later group that depends on it. An already-overwritten user edit can leave the undo stack only if the selected set will not restore other text it deleted. If the steps would restore such text together, every step contributing to that conflict stays and unrelated steps can still revert. The result does not depend on the order of the steps.

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
    |> Enum.reduce_while({:empty, %{}}, fn {task, _tick}, {first_held, excluded} ->
      case reject_steps(history, task, document, excluded) do
        {{:blocked, _, _, _} = held, excluded} ->
          {action, result} = held_press(history, held, first_held)
          {action, {result, excluded}}

        result ->
          {:halt, result}
      end
    end)
    |> elem(0)
  end

  # A press stays on the task it chose while an edit of yours holds it: `u` reaches that edit first. It moves on past a
  # task only a permanent edit holds, which no undo can reach, or when your next undo is itself blocked by a later
  # Minga step, which a press must revert first. It reports the hold it stopped on, or the first it met when every
  # task was held.
  @spec held_press(t(), tuple(), :empty | tuple()) :: {:halt | :cont, tuple()}
  defp held_press(history, {:blocked, _overlap, _task, {kind, _offset}} = held, first_held) do
    cond do
      kind == :yours and your_undo_free?(history) -> {:halt, held}
      first_held == :empty -> {:cont, held}
      true -> {:cont, first_held}
    end
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

  @spec reject_steps(t(), task(), Document.t(), RejectSelection.exclusions()) ::
          {{:ok, Restore.t(), t(), reject_summary()}
           | {:blocked, {:overlaps, :you}, task(), hold()}
           | {:error, UndoPatch.apply_error()}, RejectSelection.exclusions()}
  defp reject_steps(history, task, document, excluded) do
    steps = task_groups(history, task)
    total = step_count(steps, history)

    {selected, hold, rounds, excluded} =
      RejectSelection.plan(history.provenance, history.merges, steps, excluded)

    start = %{
      history: history,
      document: document,
      groups: [],
      dropped: [],
      first: nil,
      hold: hold,
      held_by_round: rounds
    }

    result =
      if MapSet.size(selected) == 0 do
        finish_walk(history, start, task, total)
      else
        with {:ok, walk} <- revert_groups(start, selected) do
          finish_walk(history, walk, task, total)
        end
      end

    {result, excluded}
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
        |> retire_groups(groups)
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

  @spec retire_groups(t(), [Provenance.group_id()]) :: t()
  defp retire_groups(history, groups) do
    remaining = forget_groups(history, groups)

    %{
      remaining
      | merges: retire_links(history.merges, groups),
        absorbed_steps: Map.drop(history.absorbed_steps, groups),
        saved_origins: drop_saved_origins(history.saved_origins, groups)
    }
  end

  @spec retire_links(merges(), [Provenance.group_id()]) :: merges()
  defp retire_links(links, _groups) when map_size(links) == 0, do: links
  defp retire_links(links, groups), do: Enum.reduce(groups, links, &unlink(&2, &1))

  @spec drop_saved_origins(saved_origins(), [Provenance.group_id()]) :: saved_origins()
  defp drop_saved_origins(origins, _groups) when map_size(origins) == 0, do: origins
  defp drop_saved_origins(origins, groups), do: Map.drop(origins, groups)

  # Takes reverted groups out of Minga's steps, the untasked queue, and your undo stack.
  @spec forget_groups(t(), [Provenance.group_id()]) :: t()
  defp forget_groups(history, groups) do
    {keys, remaining} =
      Enum.reduce(groups, {MapSet.new(), history}, fn group, {keys, remaining} ->
        case Map.fetch(remaining.pending_groups, group) do
          {:ok, key} -> {MapSet.put(keys, key), remove_pending(remaining, group)}
          :error -> {keys, remaining}
        end
      end)

    gone = MapSet.new(groups)

    steps =
      Enum.reduce(keys, history.steps, fn key, steps ->
        if MapSet.member?(gone, Map.get(steps, key)) and
             not pending_primary_step?(remaining, key) do
          Map.delete(steps, key)
        else
          steps
        end
      end)

    untasked = :queue.filter(&(not MapSet.member?(gone, &1)), history.untasked)
    entries = Enum.reject(history.undo_entries, &MapSet.member?(gone, &1.group))

    finished =
      keys
      |> Enum.map(&task_of/1)
      |> Enum.reject(&has_steps?(remaining, &1))

    %{
      remaining
      | steps: steps,
        untasked: untasked,
        untasked_size: :queue.len(untasked),
        undo_entries: entries,
        undo_size: length(entries),
        task_ticks: Map.drop(history.task_ticks, finished),
        task_started: Map.drop(history.task_started, finished),
        step_ticks: Map.drop(history.step_ticks, groups)
    }
  end

  @spec finish_walk(t(), map(), task(), non_neg_integer()) ::
          {:ok, Restore.t(), t(), reject_summary()}
          | {:blocked, {:overlaps, :you}, task(), hold()}
  defp finish_walk(history, %{groups: [], hold: hold}, task, _total),
    do: {:blocked, {:overlaps, :you}, task, hold_at(history.provenance, hold)}

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
      held: if(every_step?, do: nil, else: hold_at(rest.provenance, walk.hold)),
      rounds: length(walk.held_by_round),
      held_by_round: walk.held_by_round
    }

    {:ok, Restore.new(version, document, :agent), rest, summary}
  end

  @spec hold_at(Provenance.t(), RejectSelection.reason()) :: hold()
  defp hold_at(provenance, {:yours, group}), do: {:yours, group_offset(provenance, group)}

  defp hold_at(provenance, {:permanent, group}) do
    offset =
      provenance
      |> Provenance.overlapping_groups([group])
      |> Enum.find_value(0, fn
        {{:permanent, _key}, offset} -> offset
        _other -> nil
      end)

    {:permanent, offset}
  end

  @spec advance_tick(t()) :: {:advance, Entry.tick(), t()}
  defp advance_tick(history) do
    {tick, history} = advance(history)
    {:advance, tick, history}
  end

  @spec task_groups(t(), task()) :: [Provenance.group_id()]
  defp task_groups(history, task) do
    case Map.fetch(history.groups_by_task, task) do
      {:ok, groups} -> Enum.sort(groups, :desc)
      :error -> []
    end
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
      for group <- Enum.reverse(task_groups(history, {:minga, task_id})),
          do: {Map.fetch!(history.pending_groups, group), group}

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

  @doc "Returns the indivisible pending review units for a task, newest first."
  @spec review_units(t(), task()) :: [review_unit()]
  def review_units(%__MODULE__{} = history, task) do
    review_units_starting(task_groups(history, task), history)
  end

  @spec review_units_starting(Enumerable.t(), t()) :: [review_unit()]
  defp review_units_starting(groups, history) do
    {units, _pending, _by_key} =
      Enum.reduce(
        groups,
        {[], history.pending_groups, history.groups_by_step},
        fn group, acc -> add_review_unit(acc, group, {history.merges, history.absorbed_steps}) end
      )

    Enum.reverse(units)
  end

  @doc "Identifies the current review facts for this buffer history, including metadata-only decisions."
  @spec review_revision(t()) :: pos_integer()
  def review_revision(%__MODULE__{next_tick: tick}), do: tick

  @doc """
  Returns pending review regions intersecting the requested bytes in file order.

  Adjacent live sites join only when they share one whole-unit identity. Direct deletion gaps remain separate from live text. Resolve a unit once across all ranges, without scanning omitted bytes for unrelated regions.
  """
  @spec review_regions(t(), [{non_neg_integer(), non_neg_integer(), boolean()}]) ::
          [review_region()]
  def review_regions(%__MODULE__{} = history, ranges) do
    {regions, _members} = review_regions(history, ranges, %{})
    regions
  end

  @doc "Queries regions while reusing unit membership within a traversal of this history value."
  @spec review_regions(
          t(),
          [{non_neg_integer(), non_neg_integer(), boolean()}],
          %{Provenance.group_id() => Provenance.group_id()}
        ) :: {[review_region()], %{Provenance.group_id() => Provenance.group_id()}}
  def review_regions(%__MODULE__{} = history, ranges, members) do
    history.provenance
    |> sites_in_ranges(ranges)
    |> build_review_regions(history, ranges, members)
  end

  @spec build_review_regions(
          [Provenance.review_site()],
          t(),
          [{non_neg_integer(), non_neg_integer(), boolean()}],
          %{Provenance.group_id() => Provenance.group_id()}
        ) :: {[review_region()], %{Provenance.group_id() => Provenance.group_id()}}
  defp build_review_regions([], _history, _ranges, members), do: {[], members}

  defp build_review_regions(sites, history, ranges, members) do
    members =
      sites
      |> Stream.map(&elem(&1, 0))
      |> Stream.reject(&is_map_key(members, &1))
      |> review_units_starting(history)
      |> Enum.reduce(members, fn [unit | _] = groups, by_group ->
        Enum.reduce(groups, by_group, &Map.put(&2, &1, unit))
      end)

    {text, gaps} =
      Enum.reduce(sites, {%{}, MapSet.new()}, fn {group, from, to}, {text, gaps} = acc ->
        case Map.fetch(members, group) do
          {:ok, unit} when from == to ->
            {text, MapSet.put(gaps, {unit, from, to})}

          {:ok, unit} ->
            {Map.update(text, unit, [{from, to}], &join_review_region(&1, from, to)), gaps}

          :error ->
            acc
        end
      end)

    regions =
      if match?([{0, _stop, true}], ranges) do
        for {unit, intervals} <- text, {from, to} <- intervals, do: {unit, from, to}
      else
        Enum.flat_map(text, fn {unit, intervals} ->
          extend_review_regions(intervals, history.provenance, members, unit)
        end)
      end

    regions =
      Enum.sort_by(Enum.to_list(gaps) ++ regions, fn {unit, from, to} -> {from, to, unit} end)

    {regions, members}
  end

  @doc """
  Finds the next or previous distinct review head, stopping at the last reachable head.

  Navigation follows local regions, not whole units. It skips later pieces of one
  contiguous region without skipping deletion anchors inside that region.
  """
  @spec review_motion(t(), non_neg_integer(), :next | :previous, pos_integer()) ::
          non_neg_integer() | nil
  def review_motion(%__MODULE__{} = history, offset, direction, count) do
    sites = Provenance.review_sites_from(history.provenance, offset, direction)

    {_remaining, destination} =
      history
      |> motion_heads(sites, direction)
      |> Enum.reduce_while({count, nil}, fn head, {left, destination} ->
        origin = destination || offset

        cond do
          direction == :next and head <= origin -> {:cont, {left, destination}}
          direction == :previous and head >= origin -> {:cont, {left, destination}}
          left == 1 -> {:halt, {0, head}}
          true -> {:cont, {left - 1, head}}
        end
      end)

    destination
  end

  @spec motion_heads(t(), Enumerable.t(), :next | :previous) :: Enumerable.t()
  defp motion_heads(history, sites, :next) do
    Stream.transform(sites, nil, fn
      {_group, point, point}, region ->
        {[point], region}

      {_group, from, to}, {start, stop} = region when from >= start and to <= stop ->
        {[], region}

      site, _region ->
        case motion_region(history, site) do
          {head, _tail} = region -> {[head], region}
          nil -> {[], nil}
        end
    end)
  end

  defp motion_heads(history, sites, :previous) do
    sites
    |> Stream.concat([:end_of_sites])
    |> Stream.transform(nil, &previous_motion_heads(history, &1, &2))
  end

  @spec previous_motion_heads(
          t(),
          Provenance.review_site() | :end_of_sites,
          Provenance.byte_range() | nil
        ) ::
          {[non_neg_integer()], Provenance.byte_range() | nil}
  defp previous_motion_heads(_history, :end_of_sites, nil), do: {[], nil}
  defp previous_motion_heads(_history, :end_of_sites, {head, _tail}), do: {[head], nil}

  defp previous_motion_heads(history, {_group, from, _to} = site, {head, _tail})
       when from < head do
    {heads, next} = previous_motion_heads(history, site, nil)
    {[head | heads], next}
  end

  defp previous_motion_heads(_history, {_group, point, point}, region), do: {[point], region}

  defp previous_motion_heads(_history, {_group, _from, _to}, {_head, _tail} = region),
    do: {[], region}

  defp previous_motion_heads(history, site, nil), do: {[], motion_region(history, site)}

  @spec motion_region(t(), Provenance.review_site()) :: Provenance.byte_range() | nil
  defp motion_region(history, {group, from, to}) do
    case review_units_starting([group], history) do
      [[unit | _] = groups] ->
        members = Map.new(groups, &{&1, unit})
        head = extend_review_edge(history.provenance, members, unit, from, :left)
        tail = extend_review_edge(history.provenance, members, unit, to, :right)
        {head, tail}

      [] ->
        nil
    end
  end

  @spec sites_in_ranges(Provenance.t(), [{non_neg_integer(), non_neg_integer(), boolean()}]) ::
          [Provenance.review_site()]
  defp sites_in_ranges(provenance, [{first, stop, include_eof?}]),
    do: Provenance.review_sites(provenance, first, stop, include_eof?)

  defp sites_in_ranges(provenance, ranges) do
    ranges
    |> Enum.flat_map(fn {first, stop, include_eof?} ->
      Provenance.review_sites(provenance, first, stop, include_eof?)
    end)
    |> Enum.sort_by(fn {_group, from, to} -> {from, to} end)
  end

  @spec extend_review_regions(
          [Provenance.byte_range()],
          Provenance.t(),
          %{Provenance.group_id() => Provenance.group_id()},
          Provenance.group_id()
        ) :: [review_region()]
  defp extend_review_regions(ranges, provenance, members, unit) do
    Enum.reduce(ranges, [], fn
      {_from, to}, [{^unit, head, _end} | _] = regions when to > head ->
        regions

      {from, to}, regions ->
        head = extend_review_edge(provenance, members, unit, from, :left)
        tail = extend_review_edge(provenance, members, unit, to, :right)
        [{unit, head, tail} | regions]
    end)
  end

  @spec extend_review_edge(
          Provenance.t(),
          %{Provenance.group_id() => Provenance.group_id()},
          Provenance.group_id(),
          non_neg_integer(),
          :left | :right
        ) :: non_neg_integer()
  defp extend_review_edge(_prov, _members, _unit, 0, :left), do: 0

  defp extend_review_edge(prov, members, unit, edge, direction) do
    offset = if direction == :left, do: edge - 1, else: edge

    case Provenance.live_review_run_at(prov, offset) do
      {group, first, last} when :erlang.map_get(group, members) == unit ->
        next = if direction == :left, do: first, else: last
        extend_review_edge(prov, members, unit, next, direction)

      _other ->
        edge
    end
  end

  @spec join_review_region(
          [Provenance.byte_range()],
          non_neg_integer(),
          non_neg_integer()
        ) :: [Provenance.byte_range()]
  defp join_review_region([{head, stop} | rest], from, to) when from <= stop,
    do: [{head, max(stop, to)} | rest]

  defp join_review_region(ranges, from, to), do: [{from, to} | ranges]

  @doc "Checks pending membership at a byte without expanding the unit or ranking its regions."
  @spec pending_at?(t(), non_neg_integer()) :: boolean()
  def pending_at?(%__MODULE__{} = history, offset) do
    is_map_key(history.pending_groups, Provenance.review_group_at(history.provenance, offset))
  end

  @doc "Prepares whole pending units selected by task, step, current byte, or half-open byte range."
  @spec prepare_review(t(), review_selection()) :: {:ok, review_target()} | :empty
  def prepare_review(%__MODULE__{} = history, :latest) do
    case next_reject(history) do
      nil -> :empty
      task -> prepare_review(history, {:task, task})
    end
  end

  def prepare_review(%__MODULE__{} = history, {:task, task}) do
    target = Enum.map(review_units(history, task), &{task, &1})
    review_target(history, target)
  end

  def prepare_review(%__MODULE__{} = history, {:step, step}) do
    case Map.fetch(history.groups_by_step, step) do
      {:ok, groups} -> prepare_review_group(history, Enum.max(groups))
      :error -> :empty
    end
  end

  def prepare_review(%__MODULE__{} = history, {:at_byte, offset})
      when is_integer(offset) and offset >= 0 do
    case Provenance.review_group_at(history.provenance, offset) do
      nil -> :empty
      group -> prepare_review_group(history, group)
    end
  end

  def prepare_review(%__MODULE__{} = history, {:at_byte, offset, 1}),
    do: prepare_review(history, {:at_byte, offset})

  def prepare_review(%__MODULE__{} = history, {:at_byte, offset, count}) when count > 1 do
    case Provenance.review_group_at(history.provenance, offset) do
      nil ->
        :empty

      current ->
        following =
          history.provenance
          |> Provenance.review_sites_from(offset, :next)
          |> Stream.map(&elem(&1, 0))

        merges = {history.merges, history.absorbed_steps}
        initial = {history.pending_groups, history.groups_by_step}

        units =
          [current]
          |> Stream.concat(following)
          |> Stream.transform(initial, fn group, {pending, keys} ->
            {units, pending, keys} = add_review_unit({[], pending, keys}, group, merges)
            {units, {pending, keys}}
          end)
          |> Enum.take(count)
          |> Enum.map(&{review_group_task(history, hd(&1)), &1})

        review_target(history, units)
    end
  end

  def prepare_review(%__MODULE__{} = history, {:byte_range, first, stop}),
    do: prepare_review_range(history, first, stop, true)

  @doc "Prepares whole units touching a byte range, optionally including its EOF gap."
  @spec prepare_review_range(t(), non_neg_integer(), non_neg_integer(), boolean()) ::
          {:ok, review_target()} | :empty
  def prepare_review_range(%__MODULE__{} = history, first, stop, include_eof?)
      when is_integer(first) and is_integer(stop) and first >= 0 and stop >= first do
    units =
      history.provenance
      |> Provenance.review_sites(first, stop, include_eof?)
      |> Stream.map(&elem(&1, 0))
      |> review_units_starting(history)
      |> Enum.map(&{review_group_task(history, hd(&1)), &1})

    review_target(history, units)
  end

  @doc "Checks whether two pending unit representatives belong to the same task."
  @spec same_review_task?(t(), Provenance.group_id(), Provenance.group_id()) :: boolean()
  def same_review_task?(history, left, right),
    do: review_group_task(history, left) == review_group_task(history, right)

  @doc "Prepares exact whole units represented by the selected ribbons, independent of their display bounds."
  @spec prepare_review_units(t(), [Provenance.group_id()]) :: {:ok, review_target()} | :empty
  def prepare_review_units(history, representatives) do
    units =
      representatives
      |> review_units_starting(history)
      |> Enum.map(&{review_group_task(history, hd(&1)), &1})

    review_target(history, units)
  end

  @doc "Returns the whole-unit representative selected by the exact-byte review lookup."
  @spec review_unit_at(t(), non_neg_integer()) :: Provenance.group_id() | nil
  def review_unit_at(history, point) do
    with group when is_integer(group) <- Provenance.review_group_at(history.provenance, point),
         [[unit | _]] <- review_units_starting([group], history) do
      unit
    else
      _ -> nil
    end
  end

  @spec review_group_task(t(), Provenance.group_id()) :: task()
  defp review_group_task(history, group), do: task_of(Map.fetch!(history.pending_groups, group))

  @spec prepare_review_group(t(), Provenance.group_id()) :: {:ok, review_target()}
  defp prepare_review_group(history, group) do
    {[_ | _] = members, _pending, _by_step} =
      collect_review_unit(
        [group],
        history.pending_groups,
        history.groups_by_step,
        {history.merges, history.absorbed_steps},
        []
      )

    {:ok, {history.next_tick, [{review_group_task(history, group), members}]}}
  end

  @doc "Returns the scope and exact unit count an offered decision is authorized to describe."
  @spec review_summary(review_target()) :: {review_scope(), pos_integer()}
  def review_summary({_revision, [{task, _unit} | rest]}) do
    Enum.reduce(rest, {task, 1}, fn {unit_task, _unit}, {scope, count} ->
      {if(unit_task == scope, do: scope, else: :multiple_tasks), count + 1}
    end)
  end

  @doc "Reports the source footprint of the prepared Keep before history retirement."
  @spec keep_sites(t(), review_target()) :: [Provenance.byte_range()]
  def keep_sites(%__MODULE__{next_tick: revision} = history, {revision, units}) do
    Provenance.keep_sites(history.provenance, Enum.flat_map(units, &elem(&1, 1)))
  end

  def keep_sites(%__MODULE__{}, _stale_target), do: []

  @doc "Captures the exact source footprints and preimages of a prepared Keep before finalization."
  @spec keep_sources(t(), review_target()) ::
          {:ok, [Provenance.keep_source()]} | {:error, :stale_review}
  def keep_sources(%__MODULE__{next_tick: revision} = history, {revision, units}),
    do: {:ok, Provenance.keep_sources(history.provenance, Enum.flat_map(units, &elem(&1, 1)))}

  def keep_sources(%__MODULE__{}, _stale_target), do: {:error, :stale_review}

  @doc "Retires proved kept sources without changing the undo tick or the saved version."
  @spec retire_kept(t(), [Provenance.keep_interval()]) :: {t(), [Provenance.byte_range()]}
  def retire_kept(%__MODULE__{} = history, intervals) do
    {provenance, sites} = Provenance.retire_kept(history.provenance, intervals)

    if provenance === history.provenance,
      do: {history, []},
      else: {invalidate_review(%{history | provenance: provenance}), sites}
  end

  @doc "Finalizes prepared pending units without changing the document or creating a user undo."
  @spec keep_review(t(), review_target()) :: {:ok, t()} | {:error, :stale_review}
  def keep_review(%__MODULE__{next_tick: revision} = history, {revision, units}) do
    {:ok, finalize_review(history, Enum.flat_map(units, &elem(&1, 1)))}
  end

  def keep_review(%__MODULE__{}, _target), do: {:error, :stale_review}

  @doc "Keeps a prepared target and records exact source under a freshly observed Git reference."
  @spec keep_review(t(), review_target(), binary(), ReviewIdentity.t()) ::
          {:ok, t()} | {:error, :stale_review}
  def keep_review(%__MODULE__{} = history, target, content, baseline) do
    with {:ok, fragments} <- keep_sources(history, target),
         {:ok, kept} <- keep_review(history, target) do
      sources = Source.project(fragments, content)
      {:ok, %{kept | kept_review: Ledger.observe(kept.kept_review, baseline, sources)}}
    end
  end

  @doc "Returns the durable evidence for an off-mailbox proof request."
  @spec kept_review(t()) :: Ledger.t()
  def kept_review(%__MODULE__{kept_review: ledger}), do: ledger

  @doc "Binds saved evidence for buffers whose recovery swap is disabled."
  @spec bind_kept_after_save(t(), binary()) :: t()
  def bind_kept_after_save(%__MODULE__{} = history, content) do
    digest = :crypto.hash(:sha256, content)
    ledger = Ledger.save(history.kept_review, digest, content, history.provenance)
    %{history | kept_review: ledger}
  end

  @doc "Drops resolved witnesses that no current or saved kept source can still use."
  @spec prune_kept(t(), Provenance.kept_placements()) :: t()
  def prune_kept(%__MODULE__{} = history, saved_placements) do
    live_placements = Provenance.kept_placements(history.provenance)
    ledger = Ledger.prune(history.kept_review, [live_placements, saved_placements])
    %{history | kept_review: ledger}
  end

  @doc "Retires proved marks in the saved generation without changing its recorded text."
  @spec retire_kept_checkpoint(t(), saved_checkpoint() | nil, [Provenance.keep_interval()]) ::
          {:ok, saved_checkpoint() | nil, Provenance.kept_placements()}
          | {:error, :invalid_history}
  def retire_kept_checkpoint(_history, nil, _intervals), do: {:ok, nil, %{}}

  def retire_kept_checkpoint(history, {digest, snapshot} = checkpoint, intervals) do
    with {:ok, ^digest, size, saved} <- decode_snapshot(snapshot),
         {:ok, baseline} <- restore_review_snapshot(history, saved, size) do
      {retired, _sites} = retire_kept(baseline, intervals)
      placements = Provenance.kept_placements(retired.provenance)
      ledger = Ledger.prune(retired.kept_review, [placements])
      retired = %{retired | kept_review: ledger}

      checkpoint =
        if retired === baseline,
          do: checkpoint,
          else: {digest, encode_snapshot(retired, digest, size)}

      {:ok, checkpoint, placements}
    else
      _invalid -> {:error, :invalid_history}
    end
  end

  @doc "Binds the exact saved projection in live history as part of the same decision."
  @spec bind_saved_keep(t(), Ledger.t() | nil) :: t()
  def bind_saved_keep(%__MODULE__{} = history, evidence) do
    %{history | kept_review: Ledger.merge_saved(history.kept_review, evidence)}
  end

  @doc "Finalizes the same saved units without replacing the recorded disk bytes."
  @spec keep_in_checkpoint(t(), review_target(), saved_checkpoint(), saved_observation()) ::
          {:ok, saved_checkpoint(), Ledger.t() | nil} | {:error, :stale_review | :invalid_history}
  def keep_in_checkpoint(
        %__MODULE__{next_tick: revision} = history,
        {revision, units},
        {_, _} = checkpoint,
        observation
      ) do
    ids =
      Enum.reduce(units, MapSet.new(), fn {_task, groups}, ids ->
        Enum.reduce(groups, ids, &include_checkpoint_origins(history, &1, &2))
      end)

    if MapSet.size(ids) == 0 do
      {:ok, checkpoint, nil}
    else
      tasks = MapSet.new(units, &elem(&1, 0))
      keep_saved_checkpoint(history, checkpoint, tasks, ids, observation)
    end
  end

  def keep_in_checkpoint(%__MODULE__{}, _target, _checkpoint, _observation),
    do: {:error, :stale_review}

  @spec include_checkpoint_origins(t(), Provenance.group_id(), MapSet.t(Provenance.group_id())) ::
          MapSet.t(Provenance.group_id())
  defp include_checkpoint_origins(history, id, ids) do
    ids = include_saved_id(ids, id, history.saved_ceiling)

    case Map.fetch(history.saved_origins, id) do
      {:ok, origins} -> MapSet.union(ids, origins)
      :error -> ids
    end
  end

  @spec keep_saved_checkpoint(
          t(),
          saved_checkpoint(),
          MapSet.t(task()),
          MapSet.t(Provenance.group_id()),
          saved_observation()
        ) :: {:ok, saved_checkpoint(), Ledger.t() | nil} | {:error, :invalid_history}
  defp keep_saved_checkpoint(history, {digest, snapshot}, tasks, ids, observation) do
    with {:ok, ^digest, size, saved} <- decode_snapshot(snapshot),
         {:ok, baseline} <- restore_review_snapshot(history, saved, size) do
      {before, groups} = saved_keep_groups(baseline, tasks, ids)
      sources = saved_keep_sources(before.provenance, groups, digest, observation)
      kept = finalize_review(before, groups)
      evidence = bind_saved_sources(kept, observation, digest, sources)
      kept = if evidence, do: %{kept | kept_review: evidence}, else: kept
      {:ok, {digest, encode_snapshot(kept, digest, size)}, evidence}
    else
      _invalid -> {:error, :invalid_history}
    end
  end

  @spec bind_saved_sources(t(), saved_observation(), Ledger.digest(), [Source.t()]) ::
          Ledger.t() | nil
  defp bind_saved_sources(_history, _observation, _digest, []), do: nil

  defp bind_saved_sources(history, {baseline, content}, digest, sources) do
    history.kept_review
    |> Ledger.observe(baseline, sources)
    |> Ledger.save(digest, content, history.provenance)
  end

  @spec saved_keep_sources(
          Provenance.t(),
          [Provenance.group_id()],
          Ledger.digest(),
          saved_observation()
        ) ::
          [Source.t()]
  defp saved_keep_sources(_provenance, _groups, _digest, :unproven), do: []

  defp saved_keep_sources(provenance, groups, digest, {_baseline, content}) do
    if digest == :crypto.hash(:sha256, content),
      do: Source.project(Provenance.keep_sources(provenance, groups), content),
      else: []
  end

  @spec saved_keep_groups(t(), MapSet.t(task()), MapSet.t(Provenance.group_id())) ::
          {t(), [Provenance.group_id()]}
  defp saved_keep_groups(history, tasks, ids) do
    hit? = fn groups -> Enum.any?(groups, &MapSet.member?(ids, &1)) end
    applied = for task <- tasks, groups <- review_units(history, task), hit?.(groups), do: groups

    {parked, rejected} =
      Enum.reduce(history.rejected, {[], history.rejected}, fn
        {receipt, {task, groups, _coverage}}, {parked, remaining} ->
          if MapSet.member?(tasks, task) and hit?.(groups),
            do: {[groups | parked], Map.delete(remaining, receipt)},
            else: {parked, remaining}
      end)

    {%{history | rejected: rejected}, Enum.concat(applied ++ parked)}
  end

  @spec finalize_review(t(), [Provenance.group_id()]) :: t()
  defp finalize_review(history, groups) do
    history = history |> retire_review_groups(groups) |> retire_groups(groups)
    {tick, history} = advance(history)
    %{history | tick: tick, task_run: nil}
  end

  @doc "Rejects the prepared units in one pass, retaining an explicit review restore path."
  @spec reject_review(t(), review_target(), Document.t(), <<_::128>>, boolean()) ::
          {:ok, Restore.t(), t(), nonempty_list(rejected_unit())}
          | blocked()
          | {:error, review_error()}
  def reject_review(history, target, document, nonce, preserve_cursor? \\ false)

  def reject_review(
        %__MODULE__{next_tick: revision} = history,
        {revision, units},
        %Document{} = document,
        <<_::128>> = nonce,
        preserve_cursor?
      ) do
    groups = Enum.flat_map(units, &elem(&1, 1))

    with :ok <- review_allowed(history.provenance, groups, :reject),
         {:ok, reverted, first, provenance} <-
           Provenance.revert_all(history.provenance, groups, document, preserve_cursor?) do
      remaining = forget_groups(history, groups)
      {version, tick, remaining} = settle_review_reject(remaining, units)

      {rejected, receipt} =
        park_review_units(history.rejected, provenance, reverted, {nonce, revision}, units)

      remaining = %{
        remaining
        | provenance: provenance,
          rejected: rejected,
          task_run: nil,
          tick: tick
      }

      restored =
        if preserve_cursor?,
          do: reverted,
          else: place_cursor(reverted, first, Document.cursor(document))

      {:ok, Restore.new(version, restored, :agent), remaining, receipt}
    end
  end

  def reject_review(%__MODULE__{}, _target, %Document{}, _nonce, _preserve_cursor?),
    do: {:error, :stale_review}

  @doc "Restores a rejected unit only when its anchors still allow an exact reapplication."
  @spec restore_review(t(), rejected_unit(), Document.t()) ::
          {:ok, Restore.t(), t()}
          | blocked()
          | {:error, review_error() | :review_capacity}
  def restore_review(%__MODULE__{} = history, {:rejected, id}, %Document{} = document) do
    with {:ok, {task, groups, expected}} <- fetch_rejected(history, id),
         :ok <- review_allowed(history.provenance, groups, :restore),
         :ok <- retained_review_coverage(history.provenance, groups, document, expected),
         :ok <- restored_queue_capacity(history, task, groups),
         {:ok, reapplied, first, provenance} <-
           Provenance.reapply_all(history.provenance, groups, document) do
      history = %{history | provenance: provenance, rejected: Map.delete(history.rejected, id)}
      {tick, history} = advance(history)
      history = add_restored_units(%{history | tick: tick, task_run: nil}, task, groups)
      restored = place_cursor(reapplied, first, Document.cursor(document))
      {:ok, Restore.new(:advance, restored, :agent), history}
    end
  end

  @spec review_allowed(Provenance.t(), [Provenance.group_id()], :reject | :restore) ::
          :ok | blocked()
  defp review_allowed(provenance, groups, direction) do
    case Provenance.review_conflict(provenance, groups, direction) do
      nil -> :ok
      key -> {:blocked, {:overlaps, key}}
    end
  end

  @spec settle_review_reject(t(), nonempty_list(task_review_unit())) ::
          {version() | :advance, Entry.tick(), t()}
  defp settle_review_reject(history, [{task, _unit} | rest]) do
    if has_steps?(history, task) or Enum.any?(rest, &(elem(&1, 0) != task)),
      do: advance_tick(history),
      else: settle_tasks(history, [task])
  end

  @spec park_review_units(
          rejected_units(),
          Provenance.t(),
          Document.t(),
          {<<_::128>>, Entry.tick()},
          nonempty_list(task_review_unit())
        ) :: {rejected_units(), nonempty_list(rejected_unit())}
  defp park_review_units(rejected, provenance, document, {nonce, revision}, units) do
    {receipts, parked} =
      Enum.map_reduce(units, rejected, fn {task, [group | _] = groups}, parked ->
        id = {nonce, revision, group}
        proof = Provenance.review_restore_proof(provenance, groups, document)
        {{:rejected, id}, Map.put(parked, id, {task, groups, proof})}
      end)

    {parked, receipts}
  end

  @spec fetch_rejected(t(), rejection_id()) :: {:ok, parked_unit()} | {:error, :stale_review}
  defp fetch_rejected(history, id) do
    case Map.fetch(history.rejected, id) do
      {:ok, unit} -> {:ok, unit}
      :error -> {:error, :stale_review}
    end
  end

  @spec retained_review_coverage(
          Provenance.t(),
          review_unit(),
          Document.t(),
          Provenance.restore_proof()
        ) :: :ok | {:error, :stale_review}
  defp retained_review_coverage(provenance, groups, document, expected) do
    if Provenance.review_restore_proof(provenance, groups, document) == expected,
      do: :ok,
      else: {:error, :stale_review}
  end

  @spec restored_queue_capacity(t(), task(), review_unit()) :: :ok | {:error, :review_capacity}
  defp restored_queue_capacity(history, {:minga, :untasked}, groups) do
    if history.untasked_size + length(groups) <= @max_entries,
      do: :ok,
      else: {:error, :review_capacity}
  end

  defp restored_queue_capacity(_history, _task, _groups), do: :ok

  @spec add_restored_units(t(), task(), review_unit()) :: t()
  defp add_restored_units(history, {:minga, :untasked} = task, groups) do
    queue = history.untasked |> :queue.to_list() |> :lists.merge(Enum.sort(groups))

    %{
      history
      | untasked: :queue.from_list(queue),
        untasked_size: history.untasked_size + length(groups),
        task_ticks: Map.put(history.task_ticks, task, history.tick)
    }
    |> add_pending_groups(groups)
  end

  defp add_restored_units(history, task, groups) do
    [oldest | _] = ordered = Enum.sort(groups)

    entries =
      Enum.reduce(ordered, [], fn id, acc ->
        [{id, Provenance.group_key(history.provenance, id)} | acc]
      end)

    %{
      history
      | steps:
          Enum.reduce(entries, history.steps, fn {id, key}, acc ->
            Map.update(acc, key, id, &max(&1, id))
          end),
        task_started: Map.update(history.task_started, task, oldest, &min(&1, oldest)),
        task_ticks: Map.put(history.task_ticks, task, history.tick)
    }
    |> add_pending_groups(groups)
  end

  @spec review_target(t(), [task_review_unit()]) :: {:ok, review_target()} | :empty
  defp review_target(_history, []), do: :empty

  defp review_target(history, [_ | _] = units), do: {:ok, {history.next_tick, units}}

  @spec add_pending_groups(t(), [Provenance.group_id()]) :: t()
  defp add_pending_groups(history, groups) do
    Enum.reduce(groups, history, fn id, acc ->
      add_pending(acc, id, Provenance.group_key(history.provenance, id))
    end)
  end

  @spec add_pending(t(), Provenance.group_id(), minga_group()) :: t()
  defp add_pending(history, group, key) do
    %{
      history
      | pending_groups: Map.put(history.pending_groups, group, key),
        groups_by_task: add_group_to_index(history.groups_by_task, task_of(key), group),
        groups_by_step:
          index_review_keys({group, key}, history.groups_by_step, history.absorbed_steps)
    }
  end

  @spec remove_pending(t(), Provenance.group_id()) :: t()
  defp remove_pending(history, group) do
    {key, pending} = Map.pop!(history.pending_groups, group)

    by_step =
      Enum.reduce(
        Map.get(history.absorbed_steps, group, []),
        remove_group_from_index(history.groups_by_step, key, group),
        fn alias_key, index -> remove_group_from_index(index, alias_key, group) end
      )

    %{
      history
      | pending_groups: pending,
        groups_by_task: remove_group_from_index(history.groups_by_task, task_of(key), group),
        groups_by_step: by_step
    }
  end

  @spec pending_primary_step?(t(), minga_group()) :: boolean()
  defp pending_primary_step?(history, key) do
    Enum.any?(Map.get(history.groups_by_step, key, []), fn group ->
      Map.fetch!(history.pending_groups, group) == key
    end)
  end

  @spec add_group_to_index(%{key => MapSet.t(Provenance.group_id())}, key, Provenance.group_id()) ::
          %{key => MapSet.t(Provenance.group_id())}
        when key: var
  defp add_group_to_index(index, key, group) do
    case Map.fetch(index, key) do
      {:ok, groups} -> Map.put(index, key, MapSet.put(groups, group))
      :error -> Map.put(index, key, MapSet.new([group]))
    end
  end

  @spec remove_group_from_index(
          %{key => MapSet.t(Provenance.group_id())},
          key,
          Provenance.group_id()
        ) :: %{key => MapSet.t(Provenance.group_id())}
        when key: var
  defp remove_group_from_index(index, key, group) do
    groups = index |> Map.fetch!(key) |> MapSet.delete(group)

    if MapSet.size(groups) == 0, do: Map.delete(index, key), else: Map.put(index, key, groups)
  end

  @spec index_review_keys(
          {Provenance.group_id(), minga_group()},
          groups_by_step(),
          absorbed_steps()
        ) :: groups_by_step()
  defp index_review_keys({group, key}, by_key, absorbed) do
    by_key = add_group_to_index(by_key, key, group)

    Enum.reduce(Map.get(absorbed, group, []), by_key, fn alias_key, index ->
      add_group_to_index(index, alias_key, group)
    end)
  end

  @spec add_review_unit(
          {[review_unit()], pending_groups(), groups_by_step()},
          Provenance.group_id(),
          {merges(), absorbed_steps()}
        ) :: {[review_unit()], pending_groups(), groups_by_step()}
  defp add_review_unit({units, pending, by_key} = acc, group, merges) do
    if Map.has_key?(pending, group) do
      {[_ | _] = members, pending, by_key} =
        collect_review_unit([group], pending, by_key, merges, [])

      {[members | units], pending, by_key}
    else
      acc
    end
  end

  @spec collect_review_unit(
          [Provenance.group_id()],
          pending_groups(),
          groups_by_step(),
          {merges(), absorbed_steps()},
          [Provenance.group_id()]
        ) :: {[Provenance.group_id()], pending_groups(), groups_by_step()}
  # Review conflicts report the first blocker. A unit must present the same blocker whichever member opened it.
  defp collect_review_unit([], pending, by_key, _merges, members),
    do: {Enum.sort(members), pending, by_key}

  defp collect_review_unit([group | rest], pending, by_key, {merges, absorbed} = index, members) do
    case Map.pop(pending, group) do
      {nil, pending} ->
        collect_review_unit(rest, pending, by_key, index, members)

      {key, pending} ->
        {siblings, by_key} = Map.pop(by_key, key, [])
        next = Enum.reduce(siblings, rest, &[&1 | &2])
        next = Enum.reduce(Map.get(merges, group, []), next, &[&1 | &2])
        aliases = Map.get(absorbed, group, [])

        {next, by_key} =
          Enum.reduce(aliases, {next, by_key}, fn alias_key, {next, by_key} ->
            {siblings, by_key} = Map.pop(by_key, alias_key, [])
            {Enum.reduce(siblings, next, &[&1 | &2]), by_key}
          end)

        collect_review_unit(next, pending, by_key, index, [group | members])
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
          saved_origins: drop_saved_origins(rest.saved_origins, groups),
          merges: retire_links(rest.merges, groups),
          absorbed_steps: Map.drop(rest.absorbed_steps, groups)
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
  defp take_task(history, task) do
    steps =
      for group <- task_groups(history, task),
          do: {group, Map.fetch!(history.pending_groups, group)}

    remaining =
      Enum.reduce(steps, history, fn {group, _key}, acc -> remove_pending(acc, group) end)

    case task do
      {:minga, :untasked} ->
        {steps, %{remaining | untasked: :queue.new(), untasked_size: 0}}

      _task ->
        {steps,
         %{
           remaining
           | steps: Map.drop(history.steps, Enum.map(steps, &elem(&1, 1))),
             task_started: Map.delete(history.task_started, task)
         }}
    end
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
  defp has_steps?(history, task), do: Map.has_key?(history.groups_by_task, task)

  # Agent edits without a task keep their last 1000 groups, like your stack.
  # An older one becomes permanent unattributed text, and a revert can no longer return to the version before it.
  @spec cap_untasked(t()) :: t()
  defp cap_untasked(%__MODULE__{untasked_size: size} = history) when size <= @max_entries,
    do: history

  defp cap_untasked(history) do
    {{:value, oldest}, untasked} = :queue.out(history.untasked)
    history = history |> retire_untasked(oldest) |> remove_pending(oldest)

    task_run =
      case history.task_run do
        %{task: {:minga, :untasked}} = run -> %{run | fresh: false}
        run -> run
      end

    %{
      history
      | untasked: untasked,
        untasked_size: history.untasked_size - 1,
        task_run: task_run
    }
  end

  # The untasked group and the user entries it blocks retire together.
  # The stack ends at the newest blocked entry, and no compaction can run partway through.
  @spec retire_untasked(t(), Provenance.group_id()) :: t()
  defp retire_untasked(history, group) do
    case Provenance.blocked_groups(history.provenance, group) do
      [] ->
        %{history | provenance: Provenance.discard(history.provenance, group)}

      blocked ->
        blocked = MapSet.new(blocked)
        {undo_entries, dropped_undo} = cut_at_blocked(history.undo_entries, blocked)
        {redo_entries, dropped_redo} = cut_at_blocked(history.redo_entries, blocked)

        dropped =
          Enum.map(dropped_undo, & &1.group) ++ Enum.map(dropped_redo, & &1.group) ++ [group]

        %{
          history
          | provenance: Provenance.discard_all(history.provenance, dropped),
            undo_entries: undo_entries,
            undo_size: length(undo_entries),
            redo_entries: redo_entries
        }
    end
  end

  # Explicit Keep only retires user entries that depend on the kept units.
  # Their draft barriers and the kept groups disappear in a single provenance transition.
  @spec retire_review_groups(t(), [Provenance.group_id()]) :: t()
  defp retire_review_groups(%__MODULE__{undo_entries: [], redo_entries: []} = history, groups),
    do: %{history | provenance: Provenance.keep_groups(history.provenance, groups, groups)}

  defp retire_review_groups(history, groups) do
    blocked = review_user_dependents(history.provenance, groups, MapSet.new())
    keep? = fn entry -> not MapSet.member?(blocked, entry.group) end
    {undo, dropped_undo} = Enum.split_with(history.undo_entries, keep?)
    {redo, dropped_redo} = Enum.split_with(history.redo_entries, keep?)
    retired = Enum.reduce(dropped_undo, groups, &[&1.group | &2])
    retired = Enum.reduce(dropped_redo, retired, &[&1.group | &2])

    %{
      history
      | provenance: Provenance.keep_groups(history.provenance, groups, retired),
        undo_entries: undo,
        undo_size: length(undo),
        redo_entries: redo
    }
  end

  @spec review_user_dependents(Provenance.t(), [Provenance.group_id()], MapSet.t()) ::
          MapSet.t(Provenance.group_id())
  defp review_user_dependents(_provenance, [], seen), do: seen

  defp review_user_dependents(provenance, [group | rest], seen) do
    losing_bytes = Provenance.groups_losing_bytes_on_retirement(provenance, group)

    {next, seen} =
      Enum.reduce(losing_bytes, {rest, seen}, fn id, {next, seen} ->
        if Provenance.group_author(provenance, id) == :you and not MapSet.member?(seen, id),
          do: {[id | next], MapSet.put(seen, id)},
          else: {next, seen}
      end)

    review_user_dependents(provenance, next, seen)
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
       do: {run.version, run.tick_before, invalidate_review(history)}

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
         review_seen: true,
         untasked: :queue.in(group, history.untasked),
         untasked_size: history.untasked_size + 1,
         next_untasked: history.next_untasked + 1
     }
     |> add_pending(group, key)}
  end

  defp open_minga_group(history, author, key) do
    {group, provenance} = Provenance.open_group(history.provenance, author, key)

    {group,
     %{
       history
       | provenance: provenance,
         review_seen: true,
         steps: Map.put(history.steps, key, group),
         task_started: Map.put_new(history.task_started, author, group)
     }
     |> add_pending(group, key)}
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
  defp advance(history), do: {history.next_tick, invalidate_review(history)}

  # The current history tick can rewind on undo; its next allocation never does.
  @spec invalidate_review(t()) :: t()
  defp invalidate_review(history), do: %{history | next_tick: history.next_tick + 1}

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
       do:
         {entry.version, Document.move_to(document, entry.cursor), entry.tick_to,
          invalidate_review(history)}

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
