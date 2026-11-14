defmodule MingaEditor.Agent.View.PromptRenderWindow do
  @moduledoc """
  Builds a `RenderWindow` from the agent prompt buffer state.

  Translates prompt buffer content, cursor position, vim mode, visual
  selection, and paste placeholder lines into the same `RenderWindow`
  struct used by the GUI window content pipeline (0x80 opcode). This
  lets the macOS Metal renderer draw the prompt with identical cursor
  shapes, selection overlays, and styled spans as regular editor buffers.

  Visual selections retain inclusive source-byte endpoints until projection.
  Their drawn end is advanced by one source grapheme before wrapping and clipping, so the published selection ends exclusively in display coordinates.

  The prompt uses a reserved window_id (65534) that the Swift renderer
  recognizes for special positioning (bottom of the agent chat panel).

  Called from the content stage when the GUI agent chat prompt is visible.
  """

  alias MingaEditor.Agent.UIState.Panel
  alias MingaAgent.FileMention
  alias MingaEditor.Agent.ViewContext
  alias MingaEditor.Agent.SlashCommand
  alias Minga.RenderModel.Window, as: RenderWindow
  alias Minga.RenderModel.Window.DiagnosticRange
  alias Minga.RenderModel.Window.Gutter
  alias Minga.RenderModel.Window.GutterMetrics
  alias Minga.RenderModel.Window.HitRegion
  alias Minga.RenderModel.Window.IndentGuides
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.Selection
  alias Minga.RenderModel.Window.Span
  alias Minga.RenderModel.Window.Viewport, as: RenderViewport
  alias MingaEditor.Agent.View.PromptProjection
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias Minga.Core.Unicode
  alias MingaEditor.UI.Theme

  @typedoc "Agent view context."
  @type ctx :: ViewContext.t()
  @type projection :: PromptProjection.t()
  @type token_status :: :valid | :invalid
  @type token_range :: %{
          start_col: non_neg_integer(),
          end_col: non_neg_integer(),
          status: token_status()
        }
  @type token_context :: %{
          project_files: MapSet.t(String.t()),
          project_root: String.t() | nil
        }

  @doc "Reserved window_id for the agent prompt RenderWindow."
  @spec prompt_window_id() :: pos_integer()
  def prompt_window_id, do: 65_534

  @doc """
  Builds a `RenderWindow` for the agent prompt buffer.

  Returns `nil` when the agent chat is not visible or the prompt buffer
  is not available.

  The `inner_width` parameter is the number of text columns available
  inside the prompt box (excluding borders and padding). The caller
  computes this from the chat panel width.
  """
  @spec build(ctx(), pos_integer(), RenderWindow.rect() | nil, keyword()) ::
          RenderWindow.t() | nil
  def build(ctx, inner_width, rect \\ nil, opts \\ [])

  def build(%ViewContext{} = ctx, inner_width, rect, opts) when inner_width > 0 do
    panel = ctx.ui_state.panel

    if is_pid(panel.prompt_buffer) do
      build_from_panel(ctx, panel, inner_width, rect, opts)
    end
  end

  def build(_, _, _, _), do: nil

  @doc """
  Returns the prompt height in visual rows (excluding borders).

  This is the number of rows of text content the prompt displays,
  clamped to the canonical eight-row limit. Used by prompt layout helpers.
  """
  @spec visible_rows(Panel.t(), pos_integer()) :: pos_integer()
  def visible_rows(%Panel{prompt_buffer: nil}, _inner_width), do: 1

  def visible_rows(%Panel{} = panel, inner_width),
    do: PromptProjection.build(panel, inner_width).visible_rows

  @doc "Builds the visible window and its exact immutable source lease together."
  @spec build_presented(ctx(), pos_integer(), RenderWindow.rect() | nil, keyword()) ::
          {RenderWindow.t(), TextPresentation.t()} | nil
  def build_presented(%ViewContext{} = ctx, width, rect \\ nil, opts \\ []) do
    panel = ctx.ui_state.panel

    if is_pid(panel.prompt_buffer) do
      projection =
        Keyword.get_lazy(opts, :projection, fn ->
          PromptProjection.build(panel, width,
            oracle: Capabilities.width_oracle(ctx.capabilities)
          )
        end)

      model =
        build_from_panel(ctx, panel, width, rect, Keyword.put(opts, :projection, projection))

      entries =
        Enum.zip_with(model.rows, PromptProjection.visible(projection), fn row, source ->
          VisualRow.new(row, source.offset_map, source.start_col, source.end_col, 0)
        end)
        |> Enum.with_index()
        |> Enum.map(fn {entry, index} -> VisualRow.with_display_row(entry, index) end)
        |> List.to_tuple()

      identity = {projection.columns, projection.scroll, entries}

      id =
        Keyword.get_lazy(opts, :presentation_id, fn ->
          System.unique_integer([:positive, :monotonic])
        end)

      lease =
        TextPresentation.retain(
          Keyword.get(opts, :previous_presentation),
          prompt_window_id(),
          projection.buffer,
          projection.version,
          identity,
          {:windowed, entries},
          id
        )

      {%{
         model
         | text_presentation_id: lease.presentation_id,
           accessibility_generation: lease.presentation_id,
           accessibility_cursor: accessibility_cursor(model, projection, entries),
           accessibility_selection_ranges: accessibility_selection(ctx, projection, entries)
       }, lease}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec build_from_panel(ctx(), Panel.t(), pos_integer(), RenderWindow.rect() | nil, keyword()) ::
          RenderWindow.t()
  defp build_from_panel(ctx, panel, inner_width, rect, opts) do
    projection =
      Keyword.get_lazy(opts, :projection, fn ->
        PromptProjection.build(panel, inner_width,
          oracle: Capabilities.width_oracle(ctx.capabilities)
        )
      end)

    lines = projection.lines
    cursor = projection.cursor
    inner_width = projection.columns
    mode = ctx.editing.mode
    mode_state = ctx.editing.mode_state
    at = Theme.agent_theme(ctx.theme)
    total_visual = length(projection.rows)
    visible_count = projection.visible_rows
    scroll = projection.scroll
    {cursor_visual, cursor_visual_col} = PromptProjection.position(projection, cursor)
    token_context = token_context(opts)

    {visual_rows, diagnostic_ranges} =
      projection
      |> PromptProjection.visible()
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {vl, display_row}, acc ->
        logical_idx = vl.logical_line
        line_text = Enum.at(lines, logical_idx)

        {row, ranges} =
          build_visual_row(
            vl,
            line_text,
            logical_idx,
            display_row,
            panel,
            at,
            inner_width,
            token_context
          )

        {row, [ranges | acc]}
      end)

    diagnostic_ranges =
      diagnostic_ranges
      |> Enum.reverse()
      |> List.flatten()

    # Cursor position relative to the visible window
    display_cursor_row = cursor_visual - scroll
    display_cursor_col = cursor_visual_col

    cursor_shape = cursor_shape_for_mode(mode)

    # Selection overlay
    selection = build_selection(mode, mode_state, cursor, projection)

    prompt_id = prompt_window_id()
    rect = rect || {0, 0, inner_width, visible_count}

    %RenderWindow{
      window_id: prompt_id,
      content_kind: :agent_prompt,
      accessibility_label: "Agent prompt",
      rect: rect,
      rows: visual_rows,
      cursor_row: max(display_cursor_row, 0),
      cursor_col: max(display_cursor_col, 0),
      cursor_shape: cursor_shape,
      cursor_visible:
        panel.input_focused and Keyword.get(opts, :cursor_eligible, true) and
          display_cursor_row >= 0 and display_cursor_row < visible_count,
      selection: selection,
      search_matches: [],
      diagnostic_ranges: diagnostic_ranges,
      document_highlights: [],
      annotations: [],
      gutter: prompt_gutter(prompt_id, rect, panel.input_focused),
      scroll_seq: panel.prompt_viewport.sequence,
      indent_guides: IndentGuides.empty(prompt_id),
      geometry: prompt_geometry(prompt_id, rect, projection),
      content_epoch:
        prompt_content_epoch(
          prompt_id,
          rect,
          inner_width,
          visible_count,
          total_visual,
          Keyword.get(opts, :content_epoch, 0)
        ),
      full_refresh: Keyword.get(opts, :full_refresh, false)
    }
  end

  @spec prompt_content_epoch(
          pos_integer(),
          RenderWindow.rect(),
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp prompt_content_epoch(
         window_id,
         rect,
         inner_width,
         visible_count,
         total_visual,
         reset_epoch
       ) do
    :erlang.phash2({window_id, rect, inner_width, visible_count, total_visual, reset_epoch})
  end

  @spec prompt_gutter(pos_integer(), RenderWindow.rect(), boolean()) :: Gutter.t()
  defp prompt_gutter(window_id, {row, col, width, height}, active?) do
    %Gutter{
      window_id: window_id,
      content_row: row,
      content_col: col,
      content_height: height,
      is_active: active?,
      content_width: width,
      cursor_line: 0,
      line_number_style: :none,
      line_number_width: 0,
      sign_col_width: 0,
      entries: []
    }
  end

  @spec prompt_geometry(pos_integer(), RenderWindow.rect(), projection()) :: PaneGeometry.t()
  defp prompt_geometry(window_id, rect, projection) do
    first = Enum.at(projection.rows, projection.scroll)
    metrics = %GutterMetrics{line_number_width: 0, sign_col_width: 0}

    %PaneGeometry{
      window_id: window_id,
      total_rect: rect,
      content_rect: rect,
      text_rect: rect,
      gutter_rect: {elem(rect, 0), elem(rect, 1), 0, elem(rect, 3)},
      clip_rect: rect,
      viewport: %RenderViewport{
        top: first.logical_line,
        left: 0,
        rows: projection.visible_rows,
        cols: projection.columns,
        total_lines: length(projection.lines),
        visual_row_offset: first.visual_index,
        total_visual_rows: length(projection.rows)
      },
      gutter_metrics: metrics,
      hit_regions: [
        %HitRegion{kind: :text, rect: rect, window_id: window_id, target: %{window_id: window_id}}
      ]
    }
  end

  @spec build_visual_row(
          PromptProjection.visual_row(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Panel.t(),
          Theme.Agent.t(),
          pos_integer(),
          token_context()
        ) :: {Row.t(), [DiagnosticRange.t()]}
  defp build_visual_row(vl, line_text, logical_idx, display_row, _panel, at, _inner_width, ctx) do
    display_text = vl.text
    fg_color = rgb_to_int(if(vl.pill?, do: at.hint_fg, else: at.text_fg))
    bg_color = if(vl.pill?, do: paste_pill_bg(at.input_bg), else: rgb_to_int(at.input_bg))
    style_tokens? = not vl.pill?
    text_width = Unicode.display_width(display_text)
    row_start = vl.start_col
    row_end = vl.end_col
    accent_color = rgb_to_int(at.input_border)

    token_ranges =
      if style_tokens? do
        token_ranges(line_text, logical_idx, ctx)
      else
        []
      end

    valid_ranges = clipped_token_ranges(token_ranges, :valid, row_start, row_end)
    invalid_ranges = clipped_token_ranges(token_ranges, :invalid, row_start, row_end)

    spans = styled_spans(text_width, fg_color, bg_color, accent_color, valid_ranges)
    diagnostic_ranges = diagnostic_ranges(display_row, invalid_ranges)

    row = %Row{
      row_id: Row.stable_id(:normal, logical_idx, vl.visual_index),
      row_type: :normal,
      buf_line: logical_idx,
      visual_index: vl.visual_index,
      text: display_text,
      spans: spans,
      content_hash: Row.compute_hash(display_text, spans)
    }

    {row, diagnostic_ranges}
  end

  @spec token_context(keyword()) :: token_context()
  defp token_context(opts) do
    project_root = Keyword.get_lazy(opts, :project_root, &safe_project_root/0)

    project_files =
      opts
      |> Keyword.get_lazy(:project_files, &safe_project_files/0)
      |> Enum.map(&normalize_project_file/1)
      |> MapSet.new()

    %{project_root: project_root, project_files: project_files}
  end

  @spec token_ranges(String.t(), non_neg_integer(), token_context()) :: [token_range()]
  defp token_ranges(line_text, logical_idx, ctx) do
    slash_token_ranges(line_text, logical_idx) ++ mention_token_ranges(line_text, ctx)
  end

  @spec slash_token_ranges(String.t(), non_neg_integer()) :: [token_range()]
  defp slash_token_ranges("/" <> _ = line_text, 0) do
    token_length = leading_token_length(line_text)
    token = String.slice(line_text, 0, token_length)
    [%{start_col: 0, end_col: Unicode.display_width(token), status: slash_token_status(token)}]
  end

  defp slash_token_ranges(_line_text, _logical_idx), do: []

  @spec slash_token_status(String.t()) :: token_status()
  defp slash_token_status(token) do
    if SlashCommand.known_command?(token) or SlashCommand.completions(token) != [] do
      :valid
    else
      :invalid
    end
  end

  @spec leading_token_length(String.t()) :: non_neg_integer()
  defp leading_token_length(text) do
    text
    |> String.graphemes()
    |> Enum.take_while(&(&1 not in [" ", "\t", "\n"]))
    |> Enum.count()
  end

  @spec mention_token_ranges(String.t(), token_context()) :: [token_range()]
  defp mention_token_ranges(line_text, ctx) do
    line_text
    |> FileMention.extract_mentions()
    |> Enum.map(fn %{path: path, start_col: start_col, end_col: end_col} ->
      %{
        start_col: token_display_col(line_text, start_col),
        end_col: token_display_col(line_text, end_col),
        status: mention_token_status(path, ctx)
      }
    end)
  end

  @spec token_display_col(String.t(), non_neg_integer()) :: non_neg_integer()
  defp token_display_col(text, graphemes) do
    text
    |> String.graphemes()
    |> Enum.take(graphemes)
    |> Enum.reduce(0, fn
      "\t", col -> col + 2 - rem(col, 2)
      grapheme, col -> col + Unicode.grapheme_width(grapheme)
    end)
  end

  @spec mention_token_status(String.t(), token_context()) :: token_status()
  defp mention_token_status(path, ctx) do
    if known_project_file?(path, ctx) or existing_project_file?(path, ctx.project_root) do
      :valid
    else
      :invalid
    end
  end

  @spec known_project_file?(String.t(), token_context()) :: boolean()
  defp known_project_file?(path, %{project_files: project_files}) do
    MapSet.member?(project_files, normalize_project_file(path))
  end

  @spec existing_project_file?(String.t(), String.t() | nil) :: boolean()
  defp existing_project_file?(_path, nil), do: false

  defp existing_project_file?(path, project_root) do
    path
    |> Path.expand(project_root)
    |> File.regular?()
  rescue
    _ -> false
  end

  @spec clipped_token_ranges(
          [token_range()],
          token_status(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          [token_range()]
  defp clipped_token_ranges(token_ranges, status, row_start, row_end) do
    token_ranges
    |> Enum.filter(&(&1.status == status))
    |> Enum.flat_map(&clip_token_range(&1, row_start, row_end))
  end

  @spec clip_token_range(token_range(), non_neg_integer(), non_neg_integer()) :: [token_range()]
  defp clip_token_range(range, row_start, row_end) do
    start_col = max(range.start_col, row_start)
    end_col = min(range.end_col, row_end)

    if end_col > start_col do
      [%{range | start_col: start_col - row_start, end_col: end_col - row_start}]
    else
      []
    end
  end

  @spec styled_spans(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [token_range()]
        ) :: [Span.t()]
  defp styled_spans(0, _fg_color, _bg_color, _accent_color, _valid_ranges), do: []

  defp styled_spans(text_width, fg_color, bg_color, accent_color, valid_ranges) do
    valid_ranges
    |> Enum.sort_by(& &1.start_col)
    |> build_styled_spans(0, text_width, fg_color, bg_color, accent_color, [])
  end

  @spec build_styled_spans(
          [token_range()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [Span.t()]
        ) :: [Span.t()]
  defp build_styled_spans([], cursor, text_width, fg_color, bg_color, _accent_color, acc) do
    acc = maybe_add_span(acc, cursor, text_width, fg_color, bg_color)
    Enum.reverse(acc)
  end

  defp build_styled_spans(
         [%{start_col: start_col, end_col: end_col} | rest],
         cursor,
         text_width,
         fg_color,
         bg_color,
         accent_color,
         acc
       ) do
    acc = maybe_add_span(acc, cursor, start_col, fg_color, bg_color)
    acc = maybe_add_span(acc, start_col, end_col, accent_color, bg_color)
    build_styled_spans(rest, end_col, text_width, fg_color, bg_color, accent_color, acc)
  end

  @spec maybe_add_span(
          [Span.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          [Span.t()]
  defp maybe_add_span(acc, start_col, end_col, fg_color, bg_color) when end_col > start_col do
    [
      %Span{
        start_col: start_col,
        end_col: end_col,
        fg: fg_color,
        bg: bg_color,
        attrs: 0,
        font_weight: 0,
        font_id: 0
      }
      | acc
    ]
  end

  defp maybe_add_span(acc, _start_col, _end_col, _fg_color, _bg_color), do: acc

  @spec diagnostic_ranges(non_neg_integer(), [token_range()]) :: [DiagnosticRange.t()]
  defp diagnostic_ranges(display_row, invalid_ranges) do
    Enum.map(invalid_ranges, fn %{start_col: start_col, end_col: end_col} ->
      %DiagnosticRange{
        start_row: display_row,
        start_col: start_col,
        end_row: display_row,
        end_col: end_col,
        severity: :error
      }
    end)
  end

  @spec safe_project_files() :: [String.t()]
  defp safe_project_files do
    Minga.Project.files()
  catch
    :exit, _ -> []
  end

  @spec safe_project_root() :: String.t() | nil
  defp safe_project_root do
    Minga.Project.resolve_root()
  catch
    :exit, _ -> nil
  end

  @spec normalize_project_file(String.t()) :: String.t()
  defp normalize_project_file("./" <> path), do: normalize_project_file(path)
  defp normalize_project_file(path), do: path

  @spec accessibility_cursor(RenderWindow.t(), projection(), tuple()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp accessibility_cursor(%RenderWindow{cursor_visible: false}, _projection, _entries), do: nil

  defp accessibility_cursor(model, projection, entries) do
    entry = elem(entries, model.cursor_row)
    {_line, byte} = projection.cursor
    {entry.display_row, accessibility_offset(entry, byte, :start)}
  end

  @spec accessibility_selection(ctx(), projection(), tuple()) ::
          [{non_neg_integer(), non_neg_integer(), non_neg_integer()}]
  defp accessibility_selection(%{editing: %{mode: mode, mode_state: state}}, projection, entries)
       when mode in [:visual, :visual_line] do
    case Map.get(state, :visual_anchor, Map.get(state, :visual_start)) do
      {line, byte} = anchor when is_integer(line) and is_integer(byte) ->
        {from, to} =
          if anchor <= projection.cursor,
            do: {anchor, projection.cursor},
            else: {projection.cursor, anchor}

        linewise? = mode == :visual_line or Map.get(state, :visual_type) == :line
        source = Enum.at(projection.lines, elem(to, 0))
        end_exclusive = Unicode.next_grapheme_byte_offset(source, elem(to, 1))

        entries
        |> Tuple.to_list()
        |> Enum.filter(&(&1.buf_line >= elem(from, 0) and &1.buf_line <= elem(to, 0)))
        |> Enum.flat_map(&accessibility_selection_range(&1, from, to, end_exclusive, linewise?))

      _not_a_source_selection ->
        []
    end
  end

  defp accessibility_selection(_ctx, _projection, _entries), do: []

  @spec accessibility_selection_range(
          VisualRow.t(),
          PromptProjection.position(),
          PromptProjection.position(),
          non_neg_integer(),
          boolean()
        ) :: [{non_neg_integer(), non_neg_integer(), non_neg_integer()}]
  defp accessibility_selection_range(entry, _from, _to, _end_exclusive, true),
    do: [{entry.display_row, 0, row_utf16_length(entry)}]

  defp accessibility_selection_range(
         entry,
         {start_line, start_byte},
         {end_line, _end_byte},
         end_exclusive,
         false
       ) do
    start_byte = if entry.buf_line == start_line, do: start_byte, else: entry.source_start_byte
    end_byte = if entry.buf_line == end_line, do: end_exclusive, else: entry.source_end_byte
    selected_start = max(start_byte, entry.source_start_byte)
    selected_end = min(end_byte, entry.source_end_byte)

    if selected_end > selected_start do
      start_utf16 = accessibility_offset(entry, selected_start, :start)
      end_utf16 = accessibility_offset(entry, selected_end, :end)
      if end_utf16 > start_utf16, do: [{entry.display_row, start_utf16, end_utf16}], else: []
    else
      []
    end
  end

  @spec accessibility_offset(VisualRow.t(), non_neg_integer(), SourceOffsetMap.affinity()) ::
          non_neg_integer()
  defp accessibility_offset(entry, byte, affinity) do
    entry.source_offset_map
    |> SourceOffsetMap.source_to_composed_utf16(byte, affinity)
    |> Kernel.-(entry.composed_start_utf16)
    |> Kernel.+(entry.indent_width)
    |> max(0)
    |> min(row_utf16_length(entry))
  end

  @spec row_utf16_length(VisualRow.t()) :: non_neg_integer()
  defp row_utf16_length(entry),
    do: entry.indent_width + entry.composed_end_utf16 - entry.composed_start_utf16

  @spec build_selection(atom(), term(), PromptProjection.position(), projection()) ::
          Selection.t() | nil
  defp build_selection(mode, mode_state, cursor, projection)
       when mode in [:visual, :visual_line] do
    visual_start = Map.get(mode_state, :visual_anchor, Map.get(mode_state, :visual_start))
    linewise? = mode == :visual_line or Map.get(mode_state, :visual_type) == :line

    case visual_start do
      {line, byte} = anchor when is_integer(line) and is_integer(byte) ->
        {from, to} = if anchor <= cursor, do: {anchor, cursor}, else: {cursor, anchor}

        {from, to} =
          if linewise? do
            {{elem(from, 0), 0}, {elem(to, 0), byte_size(Enum.at(projection.lines, elem(to, 0)))}}
          else
            {line, byte} = to
            source = Enum.at(projection.lines, line)
            {from, {line, Unicode.next_grapheme_byte_offset(source, byte)}}
          end

        {from_row, from_col} = PromptProjection.position(projection, from)
        {to_row, to_col} = PromptProjection.position(projection, to)
        top = projection.scroll
        bottom = top + projection.visible_rows - 1

        if to_row >= top and from_row <= bottom do
          %Selection{
            type: if(linewise?, do: :line, else: :char),
            start_row: max(from_row - top, 0),
            start_col: if(from_row < top, do: 0, else: from_col),
            end_row: min(to_row, bottom) - top,
            end_col: if(to_row > bottom, do: projection.columns, else: to_col)
          }
        end

      _ ->
        nil
    end
  end

  defp build_selection(_, _, _, _), do: nil

  @spec cursor_shape_for_mode(atom()) :: RenderWindow.cursor_shape()
  defp cursor_shape_for_mode(:insert), do: :beam
  defp cursor_shape_for_mode(:normal), do: :block
  defp cursor_shape_for_mode(:visual), do: :block
  defp cursor_shape_for_mode(:visual_line), do: :block
  defp cursor_shape_for_mode(:operator_pending), do: :underline
  defp cursor_shape_for_mode(_), do: :block

  # Computes a subtle highlight background for paste pill indicators.
  # Lightens the input background by blending toward white (~10%).
  @spec paste_pill_bg(non_neg_integer()) :: non_neg_integer()
  defp paste_pill_bg(input_bg) do
    r = Bitwise.band(Bitwise.bsr(input_bg, 16), 0xFF)
    g = Bitwise.band(Bitwise.bsr(input_bg, 8), 0xFF)
    b = Bitwise.band(input_bg, 0xFF)
    # Lighten by ~10%: blend 90% original + 10% white
    r2 = min(r + div(255 - r, 10), 255)
    g2 = min(g + div(255 - g, 10), 255)
    b2 = min(b + div(255 - b, 10), 255)
    Bitwise.bor(Bitwise.bor(Bitwise.bsl(r2, 16), Bitwise.bsl(g2, 8)), b2)
  end

  # Convert a theme color integer to a 24-bit RGB integer.
  @spec rgb_to_int(non_neg_integer()) :: non_neg_integer()
  defp rgb_to_int(color), do: color
end
