defmodule MingaEditor.Renderer.WrapLayout do
  @moduledoc "Display-row measurements for editor buffer text after composition."

  alias Minga.Buffer.RenderSnapshot
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Core.PositionEncoding
  alias Minga.Core.WidthOracle
  alias Minga.Core.WrapMap
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias MingaEditor.Renderer.Composition

  @type counts :: %{optional(non_neg_integer()) => pos_integer()}

  @doc "Builds the wrap options shared by measurement and row composition."
  @spec options(pos_integer(), WidthOracle.t(), map()) :: keyword()
  def options(width, oracle, options) do
    [
      content_width: width,
      breakindent: Map.get(options, :breakindent, true),
      linebreak: Map.get(options, :linebreak, true),
      oracle: oracle,
      tab_width: Map.get(options, :tab_width, 2)
    ]
  end

  @doc "Identifies the display geometry independently of the text version."
  @spec basis(RenderSnapshot.t(), pos_integer(), WidthOracle.t(), non_neg_integer()) :: tuple()
  def basis(%RenderSnapshot{} = snapshot, width, oracle, cursor_line) do
    reveal_line = if Decorations.has_conceal_ranges?(snapshot.decorations), do: cursor_line

    {
      width,
      WidthOracle.fingerprint(oracle),
      Map.get(snapshot.options, :breakindent, true),
      Map.get(snapshot.options, :linebreak, true),
      Map.get(snapshot.options, :tab_width, 2),
      Map.get(snapshot.options, :show_invisible, false),
      snapshot.decorations.version,
      reveal_line
    }
  end

  @doc "Measures each line in a bounded render snapshot."
  @spec row_counts(RenderSnapshot.t(), pos_integer(), WidthOracle.t(), non_neg_integer()) ::
          [pos_integer()]
  def row_counts(%RenderSnapshot{} = snapshot, width, oracle, cursor_line),
    do: row_counts(snapshot, width, oracle, cursor_line, snapshot.lines)

  @doc "Measures replacement lines in the same render snapshot, for a live preview."
  @spec row_counts(
          RenderSnapshot.t(),
          pos_integer(),
          WidthOracle.t(),
          non_neg_integer(),
          [String.t()]
        ) :: [pos_integer()]
  def row_counts(%RenderSnapshot{} = snapshot, width, oracle, cursor_line, lines) do
    row_counts(snapshot, width, oracle, cursor_line, lines, %{})
  end

  @doc "Measures only lines without an exact retained count for this source and wrap basis."
  @spec row_counts(
          RenderSnapshot.t(),
          pos_integer(),
          WidthOracle.t(),
          non_neg_integer(),
          [String.t()],
          counts()
        ) :: [pos_integer()]
  def row_counts(%RenderSnapshot{} = snapshot, width, oracle, cursor_line, lines, retained) do
    options = options(width, oracle, snapshot.options)
    show_invisible? = Map.get(snapshot.options, :show_invisible, false)

    {counts, _next_line} =
      Enum.map_reduce(lines, snapshot.first_line, fn text, line ->
        count =
          case Map.fetch(retained, line) do
            {:ok, count} ->
              count

            :error ->
              row_count(text, line, snapshot.decorations, cursor_line, options, show_invisible?)
          end

        {count, line + 1}
      end)

    counts
  end

  @doc "Counts the rows of a single composed source line without materializing them."
  @spec row_count(
          String.t(),
          non_neg_integer(),
          Decorations.t(),
          non_neg_integer(),
          keyword(),
          boolean()
        ) :: pos_integer()
  def row_count(text, line, decorations, cursor_line, options, show_invisible?) do
    decorations = visible_decorations(decorations, cursor_line, line)
    tab_width = Keyword.fetch!(options, :tab_width)
    composed = compose_text(text, line, decorations, tab_width, show_invisible?)
    WrapMap.count_rows(composed, Keyword.fetch!(options, :content_width), options)
  end

  @doc "Measures a composed source line and, if requested, projects the cursor into its wrap."
  @spec measure(
          String.t(),
          non_neg_integer(),
          Decorations.t(),
          keyword(),
          boolean(),
          {non_neg_integer(), non_neg_integer() | nil}
        ) :: {String.t(), WrapMap.wrap_entry(), non_neg_integer()}
  def measure(text, line, decorations, options, show_invisible?, {cursor_line, byte}) do
    decorations = visible_decorations(decorations, cursor_line, line)
    tab_width = Keyword.fetch!(options, :tab_width)
    composed = compose_text(text, line, decorations, tab_width, show_invisible?)

    rows = wrap_composed(composed, options)

    segment =
      if line == cursor_line and is_integer(byte) and match?([_, _ | _], rows) do
        source = SourceOffsetMap.new(text, composed, decorations, line, tab_width: tab_width)
        character = SourceOffsetMap.source_to_composed_utf16(source, byte, :start)

        {_, composed_byte} =
          PositionEncoding.from_lsp(%{"line" => line, "character" => character}, composed, :utf16)

        {index, _row} = WrapMap.row_at_byte(rows, composed_byte)
        index
      else
        0
      end

    {composed, rows, segment}
  end

  defp compose_text(text, line, decorations, tab_width, show_invisible?) do
    [{text, Face.new()}]
    |> Composition.compose_segments(decorations, line)
    |> Composition.present_whitespace(tab_width, show_invisible?, nil)
    |> Enum.map_join(&elem(&1, 0))
  end

  @spec wrap_composed(String.t(), keyword()) :: WrapMap.wrap_entry()
  defp wrap_composed(text, options) do
    [rows] = WrapMap.compute([text], Keyword.fetch!(options, :content_width), options)
    rows
  end

  @spec visible_decorations(Decorations.t(), non_neg_integer(), non_neg_integer()) ::
          Decorations.t()
  defp visible_decorations(decorations, line, line) do
    if Decorations.has_conceal_ranges?(decorations),
      do: Decorations.without_conceals(decorations),
      else: decorations
  end

  defp visible_decorations(decorations, _cursor_line, _line), do: decorations
end
