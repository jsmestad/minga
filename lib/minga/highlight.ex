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

  # Fast path: tuple spans with binary search (production path from Zig)
  def styles_for_line(%__MODULE__{spans: spans} = hl, line_text, line_start_byte)
      when is_tuple(spans) and is_binary(line_text) and is_integer(line_start_byte) and
             line_start_byte >= 0 do
    line_end_byte = line_start_byte + byte_size(line_text)
    span_count = tuple_size(spans)

    # Spans are stored in a tuple sorted by start_byte. Binary search for
    # the first span that could overlap this line, then collect forward.
    start_idx = bsearch_first_overlap(spans, span_count, line_start_byte)

    overlapping = collect_overlapping(spans, span_count, start_idx, line_start_byte, line_end_byte, [])

    case overlapping do
      [] ->
        [{line_text, []}]

      _ ->
        build_segments(line_text, line_start_byte, line_end_byte, overlapping, hl)
    end
  end

  # Fallback: list spans (used by tests that construct Highlight structs directly)
  def styles_for_line(%__MODULE__{spans: spans} = hl, line_text, line_start_byte)
      when is_list(spans) and is_binary(line_text) and is_integer(line_start_byte) and
             line_start_byte >= 0 do
    styles_for_line(%{hl | spans: List.to_tuple(spans)}, line_text, line_start_byte)
  end

  # ── Private ──

  # Binary search for the first span index whose end_byte > line_start_byte.
  # This is the earliest span that could overlap the line. Spans are sorted
  # by start_byte, but a span starting before the line could extend into it,
  # so we search on end_byte to catch those.
  @spec bsearch_first_overlap(tuple(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp bsearch_first_overlap(_spans, 0, _line_start), do: 0

  defp bsearch_first_overlap(spans, count, line_start) do
    do_bsearch(spans, 0, count - 1, line_start)
  end

  @spec do_bsearch(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_bsearch(_spans, low, high, _line_start) when low > high, do: low

  defp do_bsearch(spans, low, high, line_start) do
    mid = div(low + high, 2)
    span = elem(spans, mid)

    if span.end_byte <= line_start do
      do_bsearch(spans, mid + 1, high, line_start)
    else
      do_bsearch(spans, low, mid - 1, line_start)
    end
  end

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
        # Past the line — done
        Enum.reverse(acc)

      span.end_byte > line_start ->
        # Overlaps the line
        collect_overlapping(spans, count, idx + 1, line_start, line_end, [span | acc])

      true ->
        # Ends before line starts — skip
        collect_overlapping(spans, count, idx + 1, line_start, line_end, acc)
    end
  end

  # Spans arrive from Zig pre-sorted by (start_byte ASC, pattern_index DESC,
  # end_byte ASC). This means the most specific tree-sitter pattern comes first
  # at each byte position. The left-to-right walk below uses first-wins: the
  # first span covering a position determines its style, and later spans that
  # overlap already-rendered text are skipped.

  @spec build_segments(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          [Minga.Port.Protocol.highlight_span()],
          t()
        ) :: [styled_segment()]
  defp build_segments(line_text, line_start, line_end, spans, hl) do
    do_build(line_text, line_start, line_end, spans, hl, 0, [])
  end

  @spec do_build(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          [Minga.Port.Protocol.highlight_span()],
          t(),
          non_neg_integer(),
          [styled_segment()]
        ) :: [styled_segment()]
  defp do_build(line_text, _line_start, _line_end, [], _hl, pos, acc) do
    line_len = byte_size(line_text)

    if pos < line_len do
      segment = binary_part(line_text, pos, line_len - pos)
      Enum.reverse([{segment, []} | acc])
    else
      Enum.reverse(acc)
    end
  end

  defp do_build(line_text, line_start, line_end, [span | rest], hl, pos, acc) do
    line_len = byte_size(line_text)

    # Clamp span to line boundaries (relative to line_start)
    span_start_in_line = max(span.start_byte - line_start, 0)
    span_end_in_line = min(span.end_byte - line_start, line_len)

    # Skip spans that are entirely behind our current position
    if span_end_in_line <= pos or span_start_in_line >= line_len do
      do_build(line_text, line_start, line_end, rest, hl, pos, acc)
    else
      # Adjust start to not overlap with already-rendered text
      effective_start = max(span_start_in_line, pos)

      # Gap before this span
      acc =
        if effective_start > pos do
          gap = binary_part(line_text, pos, effective_start - pos)
          [{gap, []} | acc]
        else
          acc
        end

      # The highlighted segment
      style = resolve_style(hl, span.capture_id)
      seg_len = span_end_in_line - effective_start

      acc =
        if seg_len > 0 do
          segment = binary_part(line_text, effective_start, seg_len)
          [{segment, style} | acc]
        else
          acc
        end

      do_build(line_text, line_start, line_end, rest, hl, span_end_in_line, acc)
    end
  end

  @spec resolve_style(t(), non_neg_integer()) :: Minga.Port.Protocol.style()
  defp resolve_style(hl, capture_id) do
    case Enum.at(hl.capture_names, capture_id) do
      nil -> []
      name -> Theme.style_for_capture(hl.theme, name)
    end
  end
end
