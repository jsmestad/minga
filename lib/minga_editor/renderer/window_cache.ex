defmodule MingaEditor.Renderer.WindowCache do
  @moduledoc """
  Per-window render state for incremental rendering.

  Tracks which buffer lines need re-rendering and stores last-frame comparison
  values so the render pipeline can detect when a full redraw is needed. The
  semantic `RenderModel.Window.Builder` reuses retained composed rows (see the
  `retained_rows`/`retained_wrap_lines` fields) for unchanged lines.

  ## Dirty-line tracking

  The dirty set uses two representations:

  - `:all` means every line needs re-rendering (scroll, resize, theme
    change, highlight update, fold toggle, or any other wholesale
    invalidation)
  - A map of specific buffer line numbers (`%{line => true}`) for targeted
    invalidation (edits that touch a few lines)

  ## Tracking fields

  `last_viewport_top`, `last_viewport_cache_key`, `last_gutter_w`,
  `last_line_count`, `last_cursor_line`, and `last_buf_version` store values
  from the previous frame. The Scroll stage compares current values against
  these to detect full-invalidation triggers. `last_context_fingerprint`
  captures all per-frame render context inputs (visual selection, search
  matches, syntax highlights, signs, etc.) so context changes trigger full
  redraws.
  """

  @compile {:inline, dirty?: 2}

  @typedoc """
  A retained composed row plus the cheap input fingerprint that produced it.

  The Content stage (semantic Builder) keys these by `row_id`. On the next
  frame it recomputes only the input fingerprint per row; when the fingerprint
  matches, it reuses the cached `Row.t()` verbatim instead of recomposing the
  text and spans. See `MingaEditor.RenderModel.Window.Builder` (#2287).
  """
  @type retained_row :: {input_hash :: non_neg_integer(), Minga.RenderModel.Window.Row.t()}

  @typedoc """
  A retained wrapped logical line: the cheap input fingerprint that produced its
  visual rows plus the full visual-row entry list (Rows and their wrap metadata).

  The Content stage keys these by the first visual row's durable row id. On the next
  frame, when the logical line's fingerprint (line text, highlight segments,
  compose context, and content width) is unchanged, the Builder reuses the
  entire visual-row set verbatim instead of recomposing the line and recomputing
  its wrap points. See `MingaEditor.RenderModel.Window.Builder` (#2287).
  """
  @type retained_wrap_line :: {input_hash :: non_neg_integer(), entries :: [map()]}

  @typedoc """
  Context fingerprint: a term derived from the render context that
  captures all per-frame inputs affecting every visible line. When
  the fingerprint changes between frames, all lines are re-rendered.

  Built from: visual selection, search matches, highlight version,
  diagnostic signs, git signs, viewport left scroll, active status,
  and theme color structs.
  """
  @type context_fingerprint :: term()

  alias Minga.Buffer.RenderSnapshot
  alias Minga.RenderModel.Window.LineIdentity
  alias Minga.RenderModel.Window.RowSlotAllocator
  alias MingaEditor.Renderer.ContentEpoch

  @type t :: %__MODULE__{
          dirty_lines: :all | %{optional(non_neg_integer()) => true},
          last_viewport_top: integer(),
          last_viewport_cache_key: integer(),
          last_gutter_w: integer(),
          last_line_count: integer(),
          last_cursor_line: integer(),
          last_buf_version: integer(),
          fetch_version: non_neg_integer() | nil,
          last_context_fingerprint: context_fingerprint(),
          content_epoch: non_neg_integer(),
          reset_pending: boolean(),
          last_reset_fingerprint: term(),
          total_visual_rows_cache: {term(), non_neg_integer()} | nil,
          retained_rows: %{optional(non_neg_integer()) => retained_row()},
          retained_wrap_lines: %{optional(non_neg_integer()) => retained_wrap_line()},
          line_identity: LineIdentity.t() | nil,
          identity_buffer: pid() | nil,
          applied_change_sequence: non_neg_integer(),
          row_slot_allocator: RowSlotAllocator.t(),
          resident_build: MingaEditor.RenderModel.Window.ResidentBuild.t() | nil,
          pending_edit_deltas: [Minga.Buffer.EditDelta.t()],
          changed_snapshot: RenderSnapshot.t() | nil,
          hydration_reason: atom() | nil,
          resident: boolean(),
          residence_armed: boolean(),
          scroll_seq: non_neg_integer(),
          scroll_seq_last_top: integer() | nil,
          scroll_seq_last_authoritative: non_neg_integer()
        }

  defstruct dirty_lines: %{},
            last_viewport_top: -1,
            last_viewport_cache_key: -1,
            last_gutter_w: -1,
            last_line_count: -1,
            last_cursor_line: -1,
            last_buf_version: -1,
            fetch_version: nil,
            last_context_fingerprint: nil,
            content_epoch: 0,
            reset_pending: true,
            last_reset_fingerprint: nil,
            total_visual_rows_cache: nil,
            retained_rows: %{},
            retained_wrap_lines: %{},
            line_identity: nil,
            identity_buffer: nil,
            applied_change_sequence: 0,
            row_slot_allocator: RowSlotAllocator.new(),
            resident_build: nil,
            pending_edit_deltas: [],
            changed_snapshot: nil,
            hydration_reason: nil,
            resident: false,
            residence_armed: false,
            scroll_seq: 0,
            scroll_seq_last_top: nil,
            scroll_seq_last_authoritative: 0

  @doc """
  Returns a fresh cache with all lines dirty.

  Use after any event that invalidates render state: buffer switch,
  resize, theme change, etc.
  """
  @spec reset() :: t()
  def reset do
    %__MODULE__{
      dirty_lines: :all,
      content_epoch: ContentEpoch.next(),
      hydration_reason: :initial,
      reset_pending: true,
      retained_rows: %{},
      retained_wrap_lines: %{}
    }
  end

  @doc "Returns a fresh cache invalidation while preserving retained-render epoch state."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = cache) do
    %{
      cache
      | dirty_lines: :all,
        last_viewport_top: -1,
        last_viewport_cache_key: -1,
        last_gutter_w: -1,
        last_line_count: -1,
        last_cursor_line: -1,
        last_buf_version: -1,
        last_context_fingerprint: nil,
        reset_pending: true,
        total_visual_rows_cache: nil,
        retained_rows: %{},
        retained_wrap_lines: %{},
        resident_build: nil,
        pending_edit_deltas: [],
        changed_snapshot: nil,
        residence_armed: false
    }
  end

  @doc """
  Marks specific buffer lines as needing re-render.

  Pass `:all` to force a complete redraw. Pass a list of buffer line
  numbers for targeted invalidation. If already fully dirty, adding
  specific lines is a no-op.
  """
  @spec mark_dirty(t(), [non_neg_integer()] | :all) :: t()
  def mark_dirty(%__MODULE__{} = cache, :all) do
    %{cache | dirty_lines: :all}
  end

  def mark_dirty(%__MODULE__{dirty_lines: :all} = cache, _lines), do: cache

  def mark_dirty(%__MODULE__{dirty_lines: existing} = cache, lines) when is_list(lines) do
    new_dirty = Enum.reduce(lines, existing, fn line, acc -> Map.put(acc, line, true) end)
    %{cache | dirty_lines: new_dirty}
  end

  @doc "Pins bounded line fetches to the version atomically consumed by the renderer."
  @spec with_fetch_version(t(), non_neg_integer() | nil) :: t()
  def with_fetch_version(%__MODULE__{} = cache, version), do: %{cache | fetch_version: version}

  @doc "Returns the renderer-consumed version required by bounded fetches."
  @spec fetch_version(t()) :: non_neg_integer() | nil
  def fetch_version(%__MODULE__{fetch_version: version}), do: version

  @doc "Returns true if the given buffer line needs re-rendering."
  @spec dirty?(t(), non_neg_integer()) :: boolean()
  def dirty?(%__MODULE__{dirty_lines: :all}, _line), do: true
  def dirty?(%__MODULE__{dirty_lines: dirty}, line), do: Map.has_key?(dirty, line)

  @doc """
  Checks current frame parameters against last-frame tracking fields
  and marks all lines dirty if anything requiring a full redraw has changed.

  Structural redraw triggers: viewport scroll, gutter width, line count, buffer
  version, first frame (sentinel values). Only first frame and gutter-width
  geometry changes request a retained-GUI epoch reset; ordinary text edits and
  line-count changes use row hashes without bumping the content epoch.
  """
  @spec detect_invalidation(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def detect_invalidation(%__MODULE__{} = cache, viewport_top, gutter_w, line_count, buf_version) do
    detect_invalidation(
      cache,
      viewport_top,
      viewport_top,
      gutter_w,
      line_count,
      buf_version,
      cache.last_cursor_line
    )
  end

  @spec detect_invalidation(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def detect_invalidation(
        %__MODULE__{} = cache,
        viewport_top,
        gutter_w,
        line_count,
        buf_version,
        cursor_line
      ) do
    detect_invalidation(
      cache,
      viewport_top,
      viewport_top,
      gutter_w,
      line_count,
      buf_version,
      cursor_line
    )
  end

  @spec detect_invalidation(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def detect_invalidation(
        %__MODULE__{} = cache,
        viewport_top,
        viewport_cache_key,
        gutter_w,
        line_count,
        buf_version,
        _cursor_line
      ) do
    first_frame = cache.last_buf_version < 0

    geometry_reset = first_frame or cache.last_gutter_w != gutter_w

    needs_full =
      geometry_reset or
        cache.last_viewport_top != viewport_top or
        cache.last_viewport_cache_key != viewport_cache_key or
        cache.last_line_count != line_count

    cache = if needs_full, do: %{cache | dirty_lines: :all}, else: cache
    cache = if geometry_reset, do: %{cache | reset_pending: true}, else: cache

    apply_version_invalidation(cache, buf_version)
  end

  @spec apply_version_invalidation(t(), non_neg_integer()) :: t()
  defp apply_version_invalidation(
         %__MODULE__{pending_edit_deltas: [_ | _]} = cache,
         _buf_version
       ),
       do: cache

  defp apply_version_invalidation(
         %__MODULE__{last_buf_version: previous} = cache,
         buf_version
       )
       when previous >= 0 and previous != buf_version,
       do: %{cache | dirty_lines: :all}

  defp apply_version_invalidation(cache, _buf_version), do: cache

  @doc """
  Compares the current render context fingerprint against the last frame's.

  If the fingerprint changed, marks all lines dirty. Catches changes to
  visual selection, search matches, syntax highlights, diagnostic signs,
  git signs, horizontal scroll, active/inactive status, and theme colors.
  """
  @spec detect_context_change(t(), context_fingerprint()) :: t()
  def detect_context_change(%__MODULE__{} = cache, fingerprint) do
    if cache.last_context_fingerprint != nil and
         cache.last_context_fingerprint != fingerprint do
      %{cache | dirty_lines: :all}
    else
      cache
    end
  end

  @doc "Marks the next retained GUI frame as a frontend-state reset."
  @spec mark_reset_pending(t()) :: t()
  def mark_reset_pending(%__MODULE__{} = cache) do
    %{cache | reset_pending: true}
  end

  @doc "Reconciles durable logical-line identity from one atomic buffer snapshot."
  @spec sync_line_identity(t(), pid(), RenderSnapshot.t()) :: t()
  def sync_line_identity(
        %__MODULE__{identity_buffer: existing_buffer} = cache,
        buffer,
        %RenderSnapshot{} = snapshot
      )
      when is_pid(existing_buffer) and existing_buffer != buffer do
    request_line_identity_reset(cache, buffer, snapshot)
  end

  def sync_line_identity(
        %__MODULE__{line_identity: nil} = cache,
        buffer,
        %RenderSnapshot{} = snapshot
      ) do
    epoch = max(cache.content_epoch, 1)

    %{
      cache
      | content_epoch: epoch,
        line_identity: LineIdentity.new(snapshot.line_count, epoch),
        identity_buffer: buffer,
        applied_change_sequence: snapshot.change_sequence
    }
  end

  def sync_line_identity(
        %__MODULE__{applied_change_sequence: sequence} = cache,
        _buffer,
        %RenderSnapshot{change_sequence: sequence, line_count: line_count}
      ) do
    if LineIdentity.line_count(cache.line_identity) == line_count,
      do: cache,
      else: mark_identity_reset(cache)
  end

  def sync_line_identity(%__MODULE__{} = cache, _buffer, %RenderSnapshot{}) do
    # ChangeLog interpretation is renderer-owned and happens before fetching.
    # A sequence mismatch here means consume/fetch reconciliation must retry;
    # never apply a non-mutating snapshot delta.
    mark_identity_reset(cache)
  end

  @doc "Overlays renderer-owned committed lineage onto a stale editor snapshot."
  @spec put_lineage(t(), pid(), LineIdentity.t(), non_neg_integer()) :: t()
  def put_lineage(%__MODULE__{} = cache, buffer, identity, sequence) do
    %{
      cache
      | line_identity: identity,
        identity_buffer: buffer,
        applied_change_sequence: sequence,
        content_epoch: LineIdentity.content_epoch(identity)
    }
  end

  @doc "Returns the persistent producer row-slot allocator."
  @spec row_slot_allocator(t()) :: RowSlotAllocator.t()
  def row_slot_allocator(%__MODULE__{row_slot_allocator: allocator}), do: allocator

  @doc "Stores the producer row-slot allocator after a successful content build."
  @spec put_row_slot_allocator(t(), RowSlotAllocator.t()) :: t()
  def put_row_slot_allocator(%__MODULE__{} = cache, %RowSlotAllocator{} = allocator) do
    %{cache | row_slot_allocator: allocator}
  end

  @doc "Applies renderer-consumed deltas and retains their atomic changed snapshot."
  @spec apply_edit_deltas(
          t(),
          pid(),
          [Minga.Buffer.EditDelta.t()],
          RenderSnapshot.t() | nil
        ) :: t()
  def apply_edit_deltas(
        %__MODULE__{line_identity: nil} = cache,
        _buffer,
        deltas,
        changed_snapshot
      ) do
    %{
      cache
      | pending_edit_deltas: cache.pending_edit_deltas ++ deltas,
        changed_snapshot: changed_snapshot || cache.changed_snapshot
    }
  end

  def apply_edit_deltas(%__MODULE__{} = cache, buffer, deltas, changed_snapshot)
      when is_pid(buffer) and is_list(deltas) do
    case LineIdentity.apply_edits(cache.line_identity, deltas) do
      {:ok, identity} ->
        %{
          cache
          | line_identity: identity,
            identity_buffer: buffer,
            applied_change_sequence: cache.applied_change_sequence + length(deltas),
            pending_edit_deltas: cache.pending_edit_deltas ++ deltas,
            changed_snapshot: changed_snapshot || cache.changed_snapshot
        }

      :reset_required ->
        mark_identity_reset(cache)
    end
  end

  @doc "Invalidates retained composition for full hydration while preserving residence promotion."
  @spec require_hydration(t(), atom()) :: t()
  def require_hydration(%__MODULE__{} = cache, reason \\ :reset_required) do
    cache
    |> mark_identity_reset()
    |> then(fn reset ->
      %{
        reset
        | dirty_lines: :all,
          retained_rows: %{},
          retained_wrap_lines: %{},
          total_visual_rows_cache: nil,
          hydration_reason: reason
      }
    end)
  end

  @doc "Forces the next hydration to establish a fresh durable content epoch."
  @spec mark_identity_reset(t()) :: t()
  def mark_identity_reset(%__MODULE__{} = cache) do
    %{
      cache
      | line_identity: nil,
        identity_buffer: nil,
        applied_change_sequence: 0,
        content_epoch: ContentEpoch.next(),
        row_slot_allocator: RowSlotAllocator.new(),
        resident_build: nil,
        pending_edit_deltas: [],
        changed_snapshot: nil,
        hydration_reason: :identity_reset,
        reset_pending: true
    }
  end

  @doc "Returns the sequence through which the line identity has been applied."
  @spec applied_change_sequence(t()) :: non_neg_integer()
  def applied_change_sequence(%__MODULE__{applied_change_sequence: sequence}), do: sequence

  @doc "Explicitly rebuilds durable content identity in a fresh epoch."
  @spec reset_content_identity(t(), pid(), RenderSnapshot.t()) :: t()
  def reset_content_identity(%__MODULE__{} = cache, buffer, %RenderSnapshot{} = snapshot) do
    request_line_identity_reset(cache, buffer, snapshot)
  end

  @doc "Returns the durable content epoch."
  @spec content_epoch(t()) :: non_neg_integer()
  def content_epoch(%__MODULE__{content_epoch: epoch}), do: epoch

  @doc "Returns the durable logical-line identity sequence."
  @spec line_identity(t()) :: LineIdentity.t() | nil
  def line_identity(%__MODULE__{line_identity: identity}), do: identity

  @doc "Prepares the retained GUI content epoch for the current frame."
  @spec prepare_epoch(t(), term()) :: {t(), non_neg_integer(), boolean()}
  def prepare_epoch(%__MODULE__{} = cache, reset_fingerprint) do
    reset? = cache.reset_pending or cache.last_reset_fingerprint != reset_fingerprint

    {%{
       cache
       | reset_pending: false,
         last_reset_fingerprint: reset_fingerprint
     }, cache.content_epoch, reset?}
  end

  @spec request_line_identity_reset(t(), pid(), RenderSnapshot.t()) :: t()
  defp request_line_identity_reset(cache, buffer, snapshot) do
    epoch = ContentEpoch.next()

    %{
      cache
      | content_epoch: epoch,
        line_identity: LineIdentity.new(snapshot.line_count, epoch),
        identity_buffer: buffer,
        applied_change_sequence: snapshot.change_sequence,
        row_slot_allocator: RowSlotAllocator.new(),
        hydration_reason: :identity_reset,
        reset_pending: true
    }
  end

  @doc "Returns a cached wrapped visual row total when the key matches."
  @spec cached_total_visual_rows(t(), term()) :: non_neg_integer() | nil
  def cached_total_visual_rows(%__MODULE__{total_visual_rows_cache: {key, total}}, key), do: total
  def cached_total_visual_rows(%__MODULE__{}, _key), do: nil

  @doc "Stores the wrapped visual row total for the current cache key."
  @spec put_total_visual_rows(t(), term(), non_neg_integer()) :: t()
  def put_total_visual_rows(%__MODULE__{} = cache, key, total) when is_integer(total) do
    %{cache | total_visual_rows_cache: {key, total}}
  end

  @doc """
  Snapshots tracking fields after a successful render pass.

  Clears the dirty set and records the current frame's parameters so the
  next frame can detect what changed.
  """
  @spec snapshot(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          context_fingerprint()
        ) :: t()
  def snapshot(
        %__MODULE__{} = cache,
        viewport_top,
        gutter_w,
        line_count,
        cursor_line,
        buf_version,
        ctx_fingerprint
      ) do
    snapshot(
      cache,
      viewport_top,
      viewport_top,
      gutter_w,
      line_count,
      cursor_line,
      buf_version,
      ctx_fingerprint
    )
  end

  @spec snapshot(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          context_fingerprint()
        ) :: t()
  def snapshot(
        %__MODULE__{} = cache,
        viewport_top,
        viewport_cache_key,
        gutter_w,
        line_count,
        cursor_line,
        buf_version,
        ctx_fingerprint
      ) do
    %{
      cache
      | dirty_lines: %{},
        last_viewport_top: viewport_top,
        last_viewport_cache_key: viewport_cache_key,
        last_gutter_w: gutter_w,
        last_line_count: line_count,
        last_cursor_line: cursor_line,
        last_buf_version: buf_version,
        last_context_fingerprint: ctx_fingerprint
    }
  end

  # ── Retained composed rows (#2287) ─────────────────────────────────────────

  @doc """
  Returns the `{row_id => {input_hash, Row.t()}}` map captured by the last
  semantic content build. The Builder consults it to skip recomposing rows
  whose cheap input fingerprint is unchanged.
  """
  @spec retained_rows(t()) :: %{optional(non_neg_integer()) => retained_row()}
  def retained_rows(%__MODULE__{retained_rows: rows}), do: rows

  @doc """
  Replaces the retained-row map with the current frame's composed rows.

  Stored wholesale (not merged) so the map stays bounded to the visible row
  set and never accumulates rows that scrolled out of view.
  """
  @spec put_retained_rows(t(), %{optional(non_neg_integer()) => retained_row()}) :: t()
  def put_retained_rows(%__MODULE__{} = cache, rows) when is_map(rows) do
    %{cache | retained_rows: rows}
  end

  @doc """
  Returns the `{durable_row_id => {input_hash, entries}}` map captured by the last
  semantic content build for wrapped windows. The Builder consults it to skip
  recomposing and re-wrapping logical lines whose input fingerprint is unchanged.
  """
  @spec retained_wrap_lines(t()) :: %{optional(non_neg_integer()) => retained_wrap_line()}
  def retained_wrap_lines(%__MODULE__{retained_wrap_lines: lines}), do: lines

  @doc """
  Replaces the retained wrapped-line map with the current frame's logical lines.

  Stored wholesale (not merged) so the map stays bounded to the visible logical
  lines and never accumulates lines that scrolled out of view.
  """
  @spec put_retained_wrap_lines(t(), %{optional(non_neg_integer()) => retained_wrap_line()}) ::
          t()
  def put_retained_wrap_lines(%__MODULE__{} = cache, lines) when is_map(lines) do
    %{cache | retained_wrap_lines: lines}
  end

  # ── Incremental residence build state (#2658) ──────────────────────────────

  @doc """
  Returns the persistent full-document residence build state, or `nil` when the
  window has not built on the residence path since the last reset. Carries the
  resident entry list and its incremental content digest across frames.
  """
  @spec resident_build(t()) :: MingaEditor.RenderModel.Window.ResidentBuild.t() | nil
  def resident_build(%__MODULE__{resident_build: state}), do: state

  @doc "Returns renderer-consumed deltas pending resident composition."
  @spec pending_edit_deltas(t()) :: [Minga.Buffer.EditDelta.t()]
  def pending_edit_deltas(%__MODULE__{pending_edit_deltas: deltas}), do: deltas

  @doc "Returns the atomic bounded snapshot for pending resident deltas."
  @spec changed_snapshot(t()) :: RenderSnapshot.t() | nil
  def changed_snapshot(%__MODULE__{changed_snapshot: snapshot}), do: snapshot

  @doc "Replaces the persistent residence build state captured by the last frame."
  @spec put_resident_build(t(), MingaEditor.RenderModel.Window.ResidentBuild.t() | nil) :: t()
  def put_resident_build(%__MODULE__{} = cache, state) do
    %{
      cache
      | resident_build: state,
        pending_edit_deltas: [],
        changed_snapshot: nil,
        hydration_reason: nil
    }
  end

  @doc "Returns the explicit reason for the next full resident hydration."
  @spec hydration_reason(t()) :: atom() | nil
  def hydration_reason(%__MODULE__{hydration_reason: reason}), do: reason

  # ── Scroll authority and residence flag (#2661) ─────────────────────────────

  @doc """
  Records the render pipeline's full-document residence decision for the frame.

  Lives in the render cache (not a top-level `Window` field) because the render
  cache is the only per-window struct the async render writeback copies back to
  the live window (`MingaEditor.State.merge_renderer_window/2`). The input layer
  reads it via `resident?/1`.
  """
  @spec set_resident(t(), boolean()) :: t()
  def set_resident(%__MODULE__{} = cache, resident?) when is_boolean(resident?) do
    %{cache | resident: resident?}
  end

  @doc "Returns the residence flag captured by the last rendered frame."
  @spec resident?(t()) :: boolean()
  def resident?(%__MODULE__{resident: resident}), do: resident

  @doc """
  Arms (or disarms) full-document residence for the next frame (#2679).

  First-paint-then-promote: a resident-eligible window renders viewport-windowed
  on its first frame after becoming eligible, arming promotion; the next frame
  sees `residence_armed?/1` true and emits full residence. This keeps the
  expensive O(document) first build off file-open first paint. The flag is reset
  by `reset/1` so a layout_generation rebuild (resize, font, wrap) re-defers.
  """
  @spec set_residence_armed(t(), boolean()) :: t()
  def set_residence_armed(%__MODULE__{} = cache, armed?) when is_boolean(armed?) do
    %{cache | residence_armed: armed?}
  end

  @doc "Returns whether residence was armed by the previous eligible frame (#2679)."
  @spec residence_armed?(t()) :: boolean()
  def residence_armed?(%__MODULE__{residence_armed: armed}), do: armed

  @doc "Returns the monotonic scroll-authority sequence (#2661)."
  @spec scroll_seq(t()) :: non_neg_integer()
  def scroll_seq(%__MODULE__{scroll_seq: seq}), do: seq

  @doc """
  Advances the scroll-authority sequence when this frame made a genuine
  BEAM-initiated scroll, and records the new baselines.

  `scroll_seq` bumps when EITHER of two independent signals fires:

  * **Authoritative marker (#2652):** `authoritative_seq` (the editor-owned
    `Window.authoritative_scroll_seq` request counter) moved past the last count
    this cache settled against. Command handlers increment it for the commands
    that must discard a frontend offset — at dispatch for always-authoritative
    viewport commands, and in the success branch of failable jumps (the
    `MingaEditor.Commands` `@authoritative_scroll_commands` comment is the
    source of truth for the set). This is the only signal that catches a jump
    landing exactly on the previous or echoed top (`zz` while already centered,
    a search hit already on screen), which the top comparison below cannot see.

  * **Top comparison:** `top` differs from both the previous committed top
    (`scroll_seq_last_top`) and the frontend-reported free-scroll top
    (`echo_top`). A move to the echoed top is the frontend's own report reflected
    back (a wheel/trackpad free scroll, always viewport-only), so it does not
    advance the sequence. The first settle after a fresh cache (nil baseline) does
    not bump via this path (it only records the baseline).

  The two signals are OR-combined into one bump, so a jump that both marks the
  counter and moves the top advances `scroll_seq` exactly once, never twice.

  The marker cannot latch: the render cache overwrites `scroll_seq_last_authoritative`
  to the observed counter on every settle rather than the counter being cleared on
  the live window, so a single increment causes at most one bump per rendered
  lineage. Because the counter (`scroll_seq`) and both baselines live here and the
  render cache is written back to the live window, the sequence is monotonic per
  rendered lineage; overlapped in-flight frames can emit duplicate or regressing
  values, which the frontend tolerates (strict greater-than check, with anchor-key
  and reset_required covering discards).
  """
  @spec settle_scroll_seq(t(), integer(), integer() | nil, non_neg_integer()) :: t()
  def settle_scroll_seq(%__MODULE__{} = cache, top, echo_top, authoritative_seq)
      when is_integer(top) and is_integer(authoritative_seq) do
    authoritative_move? = authoritative_seq != cache.scroll_seq_last_authoritative

    top_move? =
      not is_nil(cache.scroll_seq_last_top) and top != cache.scroll_seq_last_top and
        top != echo_top

    seq = if authoritative_move? or top_move?, do: cache.scroll_seq + 1, else: cache.scroll_seq

    %{
      cache
      | scroll_seq: seq,
        scroll_seq_last_top: top,
        scroll_seq_last_authoritative: authoritative_seq
    }
  end
end
