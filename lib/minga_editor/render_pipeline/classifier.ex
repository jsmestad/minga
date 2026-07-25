defmodule MingaEditor.RenderPipeline.Classifier do
  @moduledoc """
  Classifies a render pipeline run as a line-patch fast path or a full path (#2287).

  The classification is a telemetry and observability tag: both paths run the
  same seven stages and emit the same `begin_frame`/`commit_frame` transaction
  with the same `gui_window_content`/delta encodings. There are no new opcodes.
  What differs is the work the Content stage actually does: on the `:patch`
  path, the upstream row-retention cache lets unchanged rows skip composition,
  so a patch frame rasterizes only the rows that changed.

  ## Path meaning

  - `:patch` — cursor motion or a single-line edit confined to the active
    window's current viewport. The frame is expected to rasterize zero rows
    (pure cursor motion) or only the affected rows (a single-line edit).
  - `:full` — anything structural: a window split/open/close, a resize, a
    theme change, chrome state changes, a forced keyframe, the first frame, a
    content-epoch reset, or a viewport scroll. Multi-window frames are
    always `:full`.

  ## Conservative by construction

  Classification only ever *labels* the frame; it never suppresses work that a
  frame legitimately needs, because the row-level content hashing decides reuse
  independently. A frame mislabelled `:patch` still renders correctly, and a
  frame mislabelled `:full` is merely pessimistic. Per the ticket's risk note,
  anything ambiguous classifies as `:full`.
  """

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.Renderer.RenderWindow, as: Window

  @type path :: :patch | :full
  @type scrolls :: %{Window.id() => WindowScroll.t()}

  @doc """
  Classifies a render frame as `:patch` or `:full`.

  Consumes the prefetched per-window scroll snapshots, which already carry the
  resolved per-window invalidation (dirty lines, viewport, line count, epoch
  reset). Returns `:full` whenever a structural trigger is present or the state
  is ambiguous; otherwise `:patch`.
  """
  @spec classify(Input.t(), scrolls()) :: path()
  def classify(%Input{} = input, scrolls) when is_map(scrolls) do
    if full_path?(input, scrolls), do: :full, else: :patch
  end

  @spec full_path?(Input.t(), scrolls()) :: boolean()
  defp full_path?(%Input{} = input, scrolls) do
    input.intent.frame.force_keyframe? or
      multi_window?(scrolls) or
      active_scroll_full?(input, scrolls)
  end

  # A forced keyframe (#2219) re-emits every surface from scratch: never a patch.
  # More than one buffer window means splits, opens, or closes are in play, or an
  # agent chat window competes for the frame; classify conservatively as full.
  # An empty scroll set (no buffer windows) is also full.
  @spec multi_window?(scrolls()) :: boolean()
  defp multi_window?(scrolls), do: map_size(scrolls) != 1

  @spec active_scroll_full?(Input.t(), scrolls()) :: boolean()
  defp active_scroll_full?(%Input{windows: %{active: active}}, scrolls) do
    case Map.get(scrolls, active) do
      %WindowScroll{} = scroll -> structural_change?(scroll)
      _ -> true
    end
  end

  defp active_scroll_full?(%Input{}, _scrolls), do: true

  # A window is full when any structural trigger the patch path cannot express
  # is present: an epoch reset (geometry/first frame), a viewport scroll, a
  # line-count change (which renumbers the gutter and shifts every row), or a
  # full-dirty window with no retained rows to diff against.
  #
  # `scroll.full_refresh` is the reset-pending / frontend-reset signal: epoch
  # prep (run during prefetch, before classification) folds a pending
  # `reset_pending` — set by a theme change, a frontend recovery, or a geometry
  # reset — into this flag. So theme changes classify as `:full` per the
  # moduledoc contract without a separate check here.
  #
  # A single-line edit also marks every line dirty (the buffer version bumped)
  # but does not scroll, change the line count, or reset the epoch, so it stays
  # a patch: the row-level content hashing reuses untouched rows and composes
  # only the changed one. Targeted-dirty cursor motion is likewise a patch.
  @spec structural_change?(WindowScroll.t()) :: boolean()
  defp structural_change?(%WindowScroll{} = scroll) do
    scroll.full_refresh or
      scrolled?(scroll) or
      line_count_changed?(scroll) or
      full_dirty_without_retention?(scroll.window)
  end

  # The viewport top moved since the prior frame. `last_viewport_top` is the
  # prior frame's value; the post-render snapshot that records the new top has
  # not run yet at classification time.
  @spec scrolled?(WindowScroll.t()) :: boolean()
  defp scrolled?(%WindowScroll{viewport: %{top: top}, window: window}) do
    last = window.render_cache.last_viewport_top
    last >= 0 and top != last
  end

  @spec line_count_changed?(WindowScroll.t()) :: boolean()
  defp line_count_changed?(%WindowScroll{snapshot: snapshot, window: window}) do
    last = window.render_cache.last_line_count
    last >= 0 and snapshot.line_count != last
  end

  # A fully-dirty window is still patchable when it carries retained rows from
  # the previous frame. Without retained rows (first frame, post-reset), there
  # is nothing to diff against, so fall back to full.
  @spec full_dirty_without_retention?(Window.t()) :: boolean()
  defp full_dirty_without_retention?(%Window{} = window) do
    case window.render_cache.dirty_lines do
      :all -> map_size(Window.retained_rows(window)) == 0
      _ -> false
    end
  end
end
