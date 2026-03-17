defmodule Minga.Highlight do
  @moduledoc """
  Stores and queries tree-sitter highlight state for a buffer.

  Holds the current highlight spans (byte ranges + capture IDs),
  capture names, version counter, and theme. Provides `styles_for_line/3`
  to split a line into styled segments for rendering.
  """

  alias Minga.Theme

  @enforce_keys [:version, :spans, :capture_names, :theme]
  defstruct [:version, :spans, :capture_names, :theme]

  @typedoc "Highlight state for a buffer."
  @type t :: %__MODULE__{
          version: non_neg_integer(),
          spans: tuple() | [map()],
          capture_names: [String.t()],
          theme: Theme.syntax()
        }

  @typedoc "A styled text segment for rendering."
  @type styled_segment :: {text :: String.t(), style :: Minga.Port.Protocol.style()}

  @doc "Creates an empty highlight state with the default theme."
  @spec new() :: t()
  def new do
    %__MODULE__{
      version: 0,
      spans: {},
      capture_names: [],
      theme: Theme.get!(:doom_one).syntax
    }
  end

  @doc "Creates an empty highlight state with a syntax theme map."
  @spec new(Theme.syntax()) :: t()
  def new(theme) when is_map(theme) do
    %__MODULE__{
      version: 0,
      spans: {},
      capture_names: [],
      theme: theme
    }
  end

  @doc "Creates an empty highlight state using the syntax map from a `Minga.Theme.t()` struct."
  @spec from_theme(Minga.Theme.t()) :: t()
  def from_theme(%Minga.Theme{syntax: syntax}) do
    new(syntax)
  end

  @doc "Stores capture names from a `highlight_names` event."
  @spec put_names(t(), [String.t()]) :: t()
  def put_names(%__MODULE__{} = hl, names) when is_list(names) do
    %{hl | capture_names: names}
  end

  @doc """
  Stores highlight spans from a `highlight_spans` event.

  Only updates if the incoming version is >= the current version,
  preventing stale async results from overwriting newer ones.
  """
  @spec put_spans(t(), non_neg_integer(), [Minga.Port.Protocol.highlight_span()]) :: t()
  def put_spans(%__MODULE__{version: current} = hl, version, _spans)
      when version < current do
    hl
  end

  def put_spans(%__MODULE__{} = hl, version, spans) when is_list(spans) do
    %{hl | version: version, spans: List.to_tuple(spans)}
  end

  @doc """
  Computes the byte offset for a given line index within a list of lines.

  Each line is separated by a newline (1 byte), so the offset is the
  cumulative `byte_size` of all preceding lines plus their newlines.
  """
  @spec byte_offset_for_line([String.t()], non_neg_integer()) :: non_neg_integer()
  def byte_offset_for_line(lines, line_index)
      when is_list(lines) and is_integer(line_index) and line_index >= 0 do
    lines
    |> Enum.take(line_index)
    |> Enum.reduce(0, fn line, acc -> acc + byte_size(line) + 1 end)
  end

  @doc """
  Splits a line into styled segments based on highlight spans.

  Given a line's text and its starting byte offset within the buffer,
  finds all overlapping spans and produces `[{text_segment, style}]`.
  Unstyled regions get `[]` as their style.

  ## Examples

      iex> hl = %Minga.Highlight{
      ...>   version: 1,
      ...>   spans: [%{start_byte: 0, end_byte: 3, capture_id: 0}],
      ...>   capture_names: ["keyword"],
      ...>   theme: %{"keyword" => [fg: 0xFF0000]}
      ...> }
      iex> Minga.Highlight.styles_for_line(hl, "def foo", 0)
      [{"def", [fg: 0xFF0000]}, {" foo", []}]
  """
  @spec styles_for_line(t(), String.t(), non_neg_integer()) :: [styled_segment()]
  def styles_for_line(%__MODULE__{spans: spans}, line_text, _line_start_byte)
      when (is_tuple(spans) and tuple_size(spans) == 0) or spans == [] do
    [{line_text, []}]
  end

  # Fast path: tuple spans (production path from Zig)
  def styles_for_line(%__MODULE__{spans: spans} = hl, line_text, line_start_byte)
      when is_tuple(spans) and is_binary(line_text) and is_integer(line_start_byte) and
             line_start_byte >= 0 do
    line_end_byte = line_start_byte + byte_size(line_text)
    span_count = tuple_size(spans)

    # Linear scan from index 0: end_byte is non-monotonic in the start_byte-
    # sorted span array (a large parent can start before a line but extend
    # past it), so binary search on end_byte is unsound. The batch path
    # (styles_for_visible_lines/2) avoids this cost via an advancing watermark.
    overlapping = collect_overlapping(spans, span_count, 0, line_start_byte, line_end_byte, [])

    case overlapping do
      [] -> [{line_text, []}]
      _ -> build_segments(line_text, line_start_byte, overlapping, hl)
    end
  end

  # Fallback: list spans (used by tests that construct Highlight structs directly)
  def styles_for_line(%__MODULE__{spans: spans} = hl, line_text, line_start_byte)
      when is_list(spans) and is_binary(line_text) and is_integer(line_start_byte) and
             line_start_byte >= 0 do
    styles_for_line(%{hl | spans: List.to_tuple(spans)}, line_text, line_start_byte)
  end

  @doc """
  Batch-compute styled segments for multiple consecutive lines in a single
  pass over the span tuple. Returns a list of `[styled_segment()]` in the
  same order as the input lines.

  This is O(total_spans + total_overlapping_pairs) regardless of file size,
  compared to O(spans × visible_lines) for repeated `styles_for_line/3` calls.
  Use this for rendering visible lines.

  Each element in `lines` is `{line_text, line_start_byte}`.
  """
  @spec styles_for_visible_lines(t(), [{String.t(), non_neg_integer()}]) ::
          [[styled_segment()]]
  def styles_for_visible_lines(%__MODULE__{spans: spans}, lines)
      when (is_tuple(spans) and tuple_size(spans) == 0) or spans == [] do
    Enum.map(lines, fn {text, _} -> [{text, []}] end)
  end

  def styles_for_visible_lines(%__MODULE__{spans: spans} = hl, lines)
      when is_tuple(spans) and is_list(lines) do
    span_count = tuple_size(spans)
    {results_rev, _watermark} = batch_lines(lines, spans, span_count, hl, 0, [])
    Enum.reverse(results_rev)
  end

  # ── Private: batch rendering ─────────────────────────────────────────

  @spec batch_lines(
          [{String.t(), non_neg_integer()}],
          tuple(),
          non_neg_integer(),
          t(),
          non_neg_integer(),
          [[styled_segment()]]
        ) :: {[[styled_segment()]], non_neg_integer()}
  defp batch_lines([], _spans, _count, _hl, watermark, acc), do: {acc, watermark}

  defp batch_lines([{line_text, line_start} | rest], spans, count, hl, watermark, acc) do
    line_end = line_start + byte_size(line_text)

    # Advance watermark past spans that can't overlap this or any later line.
    watermark = advance_watermark(spans, count, watermark, line_start)

    overlapping = collect_overlapping(spans, count, watermark, line_start, line_end, [])

    segments =
      case overlapping do
        [] -> [{line_text, []}]
        _ -> build_segments(line_text, line_start, overlapping, hl)
      end

    batch_lines(rest, spans, count, hl, watermark, [segments | acc])
  end

  @spec advance_watermark(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp advance_watermark(_spans, count, idx, _line_start) when idx >= count, do: idx

  defp advance_watermark(spans, count, idx, line_start) do
    span = elem(spans, idx)

    if span.end_byte <= line_start do
      advance_watermark(spans, count, idx + 1, line_start)
    else
      idx
    end
  end

  # ── Private: overlap collection ──────────────────────────────────────

  # Collect spans that overlap [line_start, line_end) starting from start_idx.
  # Stops once spans start past the line.
  @spec collect_overlapping(
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [map()]
        ) :: [map()]
  defp collect_overlapping(_spans, count, idx, _line_start, _line_end, acc) when idx >= count do
    Enum.reverse(acc)
  end

  defp collect_overlapping(spans, count, idx, line_start, line_end, acc) do
    span = elem(spans, idx)

    cond do
      span.start_byte >= line_end ->
        Enum.reverse(acc)

      span.end_byte > line_start ->
        collect_overlapping(spans, count, idx + 1, line_start, line_end, [span | acc])

      true ->
        collect_overlapping(spans, count, idx + 1, line_start, line_end, acc)
    end
  end

  # ── Private: innermost-wins span resolution ──────────────────────────
  #
  # Tree-sitter queries emit captures on both parent and child nodes. The
  # correct rendering is *innermost-wins*: a child node's capture overrides
  # its parent's capture for the child's byte range. The parent's style
  # resumes after the child ends. Injection spans (layer > 0) always beat
  # outer spans (layer 0) at the same position.
  #
  # Algorithm:
  #   1. Convert overlapping spans to boundary events (:open / :close)
  #   2. Sort events by position (close before open at same byte)
  #   3. Walk events maintaining a sorted active set
  #   4. Priority: layer DESC, width ASC, pattern_index DESC
  #   5. Emit segments at each style-change boundary

  @spec build_segments(String.t(), non_neg_integer(), [map()], t()) :: [styled_segment()]
  defp build_segments(line_text, line_start, spans, hl) do
    # Filter out internal captures (names starting with _) before the sweep.
    # These are used by tree-sitter queries for predicate matching only,
    # not for highlighting. Neovim and Helix both skip these.
    spans = Enum.reject(spans, fn s -> internal_capture?(hl, s.capture_id) end)

    case spans do
      [] ->
        [{line_text, []}]

      _ ->
        line_len = byte_size(line_text)
        events = spans_to_events(spans, line_start, line_len)
        sweep_events(events, line_text, hl, 0, [], [])
    end
  end

  @spec internal_capture?(t(), non_neg_integer()) :: boolean()
  defp internal_capture?(hl, capture_id) do
    case Enum.at(hl.capture_names, capture_id) do
      "_" <> _ -> true
      _ -> false
    end
  end

  @typep span_event :: {non_neg_integer(), :open | :close, map()}

  @spec spans_to_events([map()], non_neg_integer(), non_neg_integer()) :: [span_event()]
  defp spans_to_events(spans, line_start, line_len) do
    spans
    |> Enum.flat_map(fn span ->
      s = max(span.start_byte - line_start, 0)
      e = min(span.end_byte - line_start, line_len)

      if e > s do
        [{s, :open, span}, {e, :close, span}]
      else
        []
      end
    end)
    |> Enum.sort_by(fn
      # Close before open at same position. Among closes, narrower first.
      # Among opens, broader first (parent opens before child).
      {pos, :close, span} ->
        width = span.end_byte - span.start_byte
        {pos, 0, width}

      {pos, :open, span} ->
        width = span.end_byte - span.start_byte
        {pos, 1, -width}
    end)
  end

  # Walk events left-to-right, emitting segments at each style change.
  # `active` is a sorted list of {layer, width, pattern_index, capture_id}
  # where hd(active) is always the winning span.
  @typep active_entry ::
           {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @spec sweep_events([span_event()], String.t(), t(), non_neg_integer(), [active_entry()], [
          styled_segment()
        ]) ::
          [styled_segment()]
  defp sweep_events([], line_text, _hl, pos, _active, acc) do
    line_len = byte_size(line_text)

    if pos < line_len do
      seg = safe_binary_slice(line_text, pos, line_len - pos)
      Enum.reverse([{seg, []} | acc])
    else
      Enum.reverse(acc)
    end
  end

  defp sweep_events([{event_pos, type, span} | rest], line_text, hl, pos, active, acc) do
    # Emit text from pos to event_pos with current winning style
    acc =
      if event_pos > pos do
        style = winning_style(active, hl)
        seg = safe_binary_slice(line_text, pos, event_pos - pos)
        [{seg, style} | acc]
      else
        acc
      end

    new_pos = max(pos, event_pos)

    layer = Map.get(span, :layer, 0)
    width = span.end_byte - span.start_byte
    pidx = Map.get(span, :pattern_index, 0)
    cid = span.capture_id
    entry = {layer, width, pidx, cid}

    active =
      case type do
        :open -> insert_active(active, entry)
        :close -> remove_active(active, entry)
      end

    sweep_events(rest, line_text, hl, new_pos, active, acc)
  end

  @spec winning_style([active_entry()], t()) :: Minga.Port.Protocol.style()
  defp winning_style([], _hl), do: []

  defp winning_style([{_layer, _width, _pidx, capture_id} | _], hl),
    do: resolve_style(hl, capture_id)

  # Insert into active set maintaining priority order:
  # (layer DESC, width ASC, pattern_index DESC)
  # The head is always the winner.
  @spec insert_active([active_entry()], active_entry()) :: [active_entry()]
  defp insert_active([], entry), do: [entry]

  defp insert_active([{hl, hw, hp, _} = head | tail], {el, ew, ep, _} = entry) do
    cond do
      el > hl -> [entry, head | tail]
      el < hl -> [head | insert_active(tail, entry)]
      ew < hw -> [entry, head | tail]
      ew > hw -> [head | insert_active(tail, entry)]
      ep > hp -> [entry, head | tail]
      true -> [head | insert_active(tail, entry)]
    end
  end

  @spec remove_active([active_entry()], active_entry()) :: [active_entry()]
  defp remove_active([], _entry), do: []
  defp remove_active([entry | tail], entry), do: tail
  defp remove_active([head | tail], entry), do: [head | remove_active(tail, entry)]

  @spec resolve_style(t(), non_neg_integer()) :: Minga.Port.Protocol.style()
  defp resolve_style(hl, capture_id) do
    case Enum.at(hl.capture_names, capture_id) do
      nil -> []
      name -> Theme.style_for_capture(hl.theme, name)
    end
  end

  # Safely extract a substring using byte offsets. When highlight spans are
  # stale (buffer edited since last highlight), byte offsets can land
  # mid-codepoint, producing invalid UTF-8. This snaps offsets to the nearest
  # valid character boundary to avoid downstream crashes in display_width.
  @spec safe_binary_slice(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  defp safe_binary_slice(text, start, len) when start >= 0 and len >= 0 do
    text_len = byte_size(text)
    clamped_start = min(start, text_len)
    clamped_len = min(len, text_len - clamped_start)

    result = binary_part(text, clamped_start, clamped_len)

    if String.valid?(result) do
      result
    else
      # Byte offsets are misaligned with character boundaries. Fall back to
      # the full remaining text from `start` so we don't lose content.
      remaining = binary_part(text, clamped_start, text_len - clamped_start)

      if String.valid?(remaining) do
        remaining
      else
        # Extremely stale spans. Return empty to skip rather than crash.
        ""
      end
    end
  end
end
