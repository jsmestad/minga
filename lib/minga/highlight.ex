defmodule Minga.Highlight do
  @moduledoc """
  Stores and queries tree-sitter highlight state for a buffer.

  Holds the current highlight spans (byte ranges + capture IDs),
  capture names, version counter, and theme. Provides `styles_for_line/3`
  to split a line into styled segments for rendering.
  """

  alias Minga.Highlight.Theme

  @enforce_keys [:version, :spans, :capture_names, :theme]
  defstruct [:version, :spans, :capture_names, :theme]

  @typedoc "Highlight state for a buffer."
  @type t :: %__MODULE__{
          version: non_neg_integer(),
          spans: [Minga.Port.Protocol.highlight_span()],
          capture_names: [String.t()],
          theme: Theme.t()
        }

  @typedoc "A styled text segment for rendering."
  @type styled_segment :: {text :: String.t(), style :: Minga.Port.Protocol.style()}

  @doc "Creates an empty highlight state with the default theme."
  @spec new() :: t()
  def new do
    %__MODULE__{
      version: 0,
      spans: [],
      capture_names: [],
      theme: Theme.doom_one()
    }
  end

  @doc "Creates an empty highlight state with a custom theme."
  @spec new(Theme.t()) :: t()
  def new(theme) when is_map(theme) do
    %__MODULE__{
      version: 0,
      spans: [],
      capture_names: [],
      theme: theme
    }
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
    %{hl | version: version, spans: spans}
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
  def styles_for_line(%__MODULE__{spans: []}, line_text, _line_start_byte) do
    [{line_text, []}]
  end

  def styles_for_line(%__MODULE__{} = hl, line_text, line_start_byte)
      when is_binary(line_text) and is_integer(line_start_byte) and line_start_byte >= 0 do
    line_end_byte = line_start_byte + byte_size(line_text)

    # Find spans that overlap this line
    overlapping =
      hl.spans
      |> Enum.filter(fn span ->
        span.start_byte < line_end_byte and span.end_byte > line_start_byte
      end)
      |> Enum.sort_by(& &1.start_byte)

    case overlapping do
      [] ->
        [{line_text, []}]

      _ ->
        build_segments(line_text, line_start_byte, line_end_byte, overlapping, hl)
    end
  end

  # ── Private ──

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

    # Gap before this span
    acc =
      if span_start_in_line > pos do
        gap = binary_part(line_text, pos, span_start_in_line - pos)
        [{gap, []} | acc]
      else
        acc
      end

    # The highlighted segment
    style = resolve_style(hl, span.capture_id)
    seg_len = span_end_in_line - span_start_in_line

    acc =
      if seg_len > 0 do
        segment = binary_part(line_text, span_start_in_line, seg_len)
        [{segment, style} | acc]
      else
        acc
      end

    do_build(line_text, line_start, line_end, rest, hl, span_end_in_line, acc)
  end

  @spec resolve_style(t(), non_neg_integer()) :: Minga.Port.Protocol.style()
  defp resolve_style(hl, capture_id) do
    case Enum.at(hl.capture_names, capture_id) do
      nil -> []
      name -> Theme.style_for_capture(hl.theme, name)
    end
  end
end
