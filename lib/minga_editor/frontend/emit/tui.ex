defmodule MingaEditor.Frontend.Emit.TUI do
  @moduledoc """
  TUI-specific command building for the Emit stage.

  Converts a composed `Frame` into protocol command binaries for the
  Zig/libvaxis TUI renderer. Handles scroll region optimization when
  the viewport shifts by a small delta between frames.

  ## Scroll region optimization

  When the viewport shifts by 1-3 lines between frames and no structural
  changes occurred (layout, gutter width, window set, buffer content), we
  send a `scroll_region` command instead of a full `clear + redraw`. The
  terminal emulator shifts its internal buffer, then only the newly
  revealed lines are drawn. This eliminates the majority of cell writes
  for the most common scroll case (Ctrl-e/y, mouse wheel, cursor near
  edges).

  The Zig renderer syncs its internal libvaxis screen buffers after
  sending the ANSI scroll region sequences (`VaxisSurface.scrollRegion`),
  so the subsequent `render()` diff only repaints the newly revealed rows.

  Bails out to a full redraw when the editing mode changed since the last
  frame (e.g., exiting visual mode would leave stale selection highlights
  on shifted rows) or when the current mode has per-frame visual state
  changes that affect content styling (visual selection, search highlights).
  """

  alias Minga.Core.Face
  alias Minga.Core.Unicode
  alias Minga.Frontend.Adapter.TUI.WindowAdapter
  alias Minga.RenderModel
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Frame, Overlay, WindowFrame}
  alias MingaEditor.Layout
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Renderer.Caches

  @typedoc "Emit context for the TUI stage."
  @type ctx :: Context.t()

  @typedoc "Scroll delta info for one window."
  @type scroll_delta :: %{
          required(:win_id) => pos_integer(),
          required(:delta) => integer(),
          required(:content_rect) => Layout.rect(),
          optional(:redraw_rows) => [non_neg_integer()]
        }

  # Maximum viewport delta for scroll region optimization.
  @max_scroll_delta 3

  @doc """
  Builds protocol command binaries from a render model for the TUI renderer.

  Detects scroll regions from tracking state and uses scroll region optimization when possible, otherwise does a full redraw. Buffer-window output comes from `Minga.RenderModel`; the legacy frame supplies TUI chrome until the chrome adapter is fully semantic.
  """
  @spec build_commands(RenderModel.t(), Frame.t(), ctx(), Caches.t()) :: [binary()]
  def build_commands(%RenderModel{} = render_model, %Frame{} = frame, ctx, caches) do
    scroll_deltas = detect_scroll_regions(ctx, caches)
    build_commands_from_deltas(render_model, frame, ctx, scroll_deltas)
  end

  @doc """
  Builds protocol command binaries from a frame for legacy callers.

  Production TUI emit passes a `Minga.RenderModel`; this arity remains for focused tests and compatibility fallbacks.
  """
  @spec build_commands(Frame.t(), ctx(), Caches.t()) :: [binary()]
  def build_commands(frame, ctx, caches) do
    scroll_deltas = detect_scroll_regions(ctx, caches)
    build_commands_from_deltas(frame, scroll_deltas)
  end

  @doc """
  Builds protocol commands from a render model, compatibility frame, and pre-computed scroll deltas.

  When `scroll_deltas` is nil, performs a full redraw with model-derived buffer windows. When scroll deltas are present, sends scroll_region commands plus newly exposed model-derived window rows and compatibility chrome.
  """
  @spec build_commands_from_deltas(RenderModel.t(), Frame.t(), ctx(), [scroll_delta()] | nil) :: [
          binary()
        ]
  def build_commands_from_deltas(%RenderModel{windows: []}, %Frame{} = frame, _ctx, scroll_deltas) do
    build_commands_from_deltas(frame, scroll_deltas)
  end

  def build_commands_from_deltas(%RenderModel{} = render_model, %Frame{} = frame, ctx, nil) do
    build_full_redraw_from_model(render_model, frame, ctx)
  end

  def build_commands_from_deltas(
        %RenderModel{} = render_model,
        %Frame{} = frame,
        ctx,
        scroll_deltas
      ) do
    scroll_cmds = build_scroll_commands(scroll_deltas)

    new_content_draws =
      collect_redraw_row_clear_draws(scroll_deltas) ++
        collect_new_model_window_draws(render_model, ctx, scroll_deltas)

    chrome_draws = collect_chrome_draws(frame) ++ collect_model_window_legacy_draws(frame)
    overlay_draws = collect_overlay_draws(frame)

    scroll_cmds ++
      frame.regions ++
      DisplayList.draws_to_commands(chrome_draws) ++
      DisplayList.draws_to_commands(new_content_draws) ++
      DisplayList.draws_to_commands(overlay_draws) ++
      [
        Protocol.encode_cursor_shape(frame.cursor.shape),
        Protocol.encode_cursor(frame.cursor.row, frame.cursor.col),
        Protocol.encode_batch_end()
      ]
  end

  @doc """
  Builds protocol commands from a frame and pre-computed scroll deltas.

  When `scroll_deltas` is nil, performs a full redraw via `DisplayList.to_commands/1`. When scroll deltas are present, sends scroll_region commands plus partial content and chrome.
  """
  @spec build_commands_from_deltas(Frame.t(), [scroll_delta()] | nil) :: [binary()]
  def build_commands_from_deltas(frame, nil) do
    DisplayList.to_commands(frame)
  end

  def build_commands_from_deltas(frame, scroll_deltas) do
    scroll_cmds = build_scroll_commands(scroll_deltas)

    new_content_draws =
      collect_redraw_row_clear_draws(scroll_deltas) ++
        collect_new_content_draws(frame, scroll_deltas)

    chrome_draws = collect_chrome_draws(frame)
    overlay_draws = collect_overlay_draws(frame)

    scroll_cmds ++
      frame.regions ++
      DisplayList.draws_to_commands(chrome_draws) ++
      DisplayList.draws_to_commands(new_content_draws) ++
      DisplayList.draws_to_commands(overlay_draws) ++
      [
        Protocol.encode_cursor_shape(frame.cursor.shape),
        Protocol.encode_cursor(frame.cursor.row, frame.cursor.col),
        Protocol.encode_batch_end()
      ]
  end

  @spec build_full_redraw_from_model(RenderModel.t(), Frame.t(), ctx()) :: [binary()]
  defp build_full_redraw_from_model(%RenderModel{} = render_model, %Frame{} = frame, ctx) do
    splash_draws = frame.splash || []
    before_windows = frame.tab_bar ++ frame.file_tree ++ frame.agentic_view

    after_windows =
      frame.separators ++
        frame.status_bar ++ frame.agent_panel ++ frame.minibuffer ++ splash_draws

    legacy_window_draws = collect_model_window_legacy_draws(frame)
    overlay_draws = collect_overlay_draws(frame)

    [Protocol.encode_clear()] ++
      frame.regions ++
      DisplayList.draws_to_commands(before_windows) ++
      model_window_commands(render_model, ctx) ++
      DisplayList.draws_to_commands(legacy_window_draws) ++
      DisplayList.draws_to_commands(after_windows) ++
      DisplayList.draws_to_commands(overlay_draws) ++
      [
        Protocol.encode_cursor_shape(frame.cursor.shape),
        Protocol.encode_cursor(frame.cursor.row, frame.cursor.col),
        Protocol.encode_batch_end()
      ]
  end

  @spec model_window_commands(RenderModel.t(), ctx()) :: [binary()]
  defp model_window_commands(%RenderModel{} = render_model, ctx) do
    render_model
    |> model_window_draws(ctx)
    |> DisplayList.draws_to_commands()
  end

  @spec collect_new_model_window_draws(RenderModel.t(), ctx(), [scroll_delta()]) :: [
          DisplayList.draw()
        ]
  defp collect_new_model_window_draws(%RenderModel{} = render_model, ctx, scroll_deltas) do
    ranges = redraw_ranges(scroll_deltas)

    render_model
    |> model_window_draws(ctx)
    |> filter_draws_by_ranges(ranges)
  end

  @spec collect_redraw_row_clear_draws([scroll_delta()]) :: [DisplayList.draw()]
  defp collect_redraw_row_clear_draws(scroll_deltas) do
    Enum.flat_map(scroll_deltas, &redraw_row_clear_draws/1)
  end

  @spec redraw_row_clear_draws(scroll_delta()) :: [DisplayList.draw()]
  defp redraw_row_clear_draws(%{content_rect: {_top, col, width, _height}, redraw_rows: rows})
       when is_list(rows) and width > 0 do
    text = String.duplicate(" ", width)

    rows
    |> Enum.uniq()
    |> Enum.map(fn row -> DisplayList.draw(row, col, text, Face.new()) end)
  end

  defp redraw_row_clear_draws(_delta), do: []

  @spec model_window_draws(RenderModel.t(), ctx()) :: [DisplayList.draw()]
  defp model_window_draws(%RenderModel{windows: windows}, ctx) do
    opts = window_adapter_opts(ctx)

    windows
    |> Enum.flat_map(&WindowAdapter.to_screen_cells(&1, opts))
    |> cells_to_draws()
  end

  @spec collect_model_window_legacy_draws(Frame.t()) :: [DisplayList.draw()]
  defp collect_model_window_legacy_draws(%Frame{} = frame) do
    Enum.flat_map(frame.windows, fn
      %WindowFrame{window_model: %{content_kind: :agent_chat}, lines: lines} ->
        DisplayList.layer_to_draws(lines)

      %WindowFrame{} ->
        []
    end)
  end

  @spec cells_to_draws([WindowAdapter.cell()]) :: [DisplayList.draw()]
  defp cells_to_draws(cells) do
    cells
    |> Enum.sort_by(fn %{row: row, col: col} -> {row, col} end)
    |> Enum.reduce([], &append_cell_draw/2)
    |> Enum.reverse()
  end

  @spec append_cell_draw(WindowAdapter.cell(), [DisplayList.draw()]) :: [DisplayList.draw()]
  defp append_cell_draw(%{row: row, col: col, text: text, face: %Face{} = face}, [
         {row, start_col, existing_text, %Face{} = face} | rest
       ]) do
    expected_col = start_col + Unicode.display_width(existing_text)

    if col == expected_col do
      [{row, start_col, existing_text <> text, face} | rest]
    else
      [DisplayList.draw(row, col, text, face), {row, start_col, existing_text, face} | rest]
    end
  end

  defp append_cell_draw(%{row: row, col: col, text: text, face: %Face{} = face}, acc) do
    [DisplayList.draw(row, col, text, face) | acc]
  end

  @spec filter_draws_by_ranges([DisplayList.draw()], [Range.t()]) :: [DisplayList.draw()]
  defp filter_draws_by_ranges(draws, ranges) do
    Enum.filter(draws, fn {row, _col, _text, _style} ->
      Enum.any?(ranges, fn range -> row in range end)
    end)
  end

  @spec window_adapter_opts(ctx()) :: keyword()
  defp window_adapter_opts(%Context{theme: theme}) do
    [
      selection_bg: theme.editor.selection_bg || 0x3E4451,
      search_bg: theme.search.highlight_bg,
      current_search_bg: theme.search.current_bg,
      gutter_fg: theme.gutter.fg,
      gutter_current_fg: theme.gutter.current_fg,
      gutter_error_fg: theme.gutter.error_fg,
      gutter_warning_fg: theme.gutter.warning_fg,
      gutter_info_fg: theme.gutter.info_fg,
      gutter_hint_fg: theme.gutter.hint_fg,
      gutter_fold_fg: theme.gutter.fold_fg,
      indent_guide_fg: theme.editor.indent_guide_fg || theme.gutter.fg,
      indent_guide_active_fg: theme.editor.indent_guide_active_fg || theme.gutter.current_fg,
      git_added_fg: theme.git.added_fg,
      git_modified_fg: theme.git.modified_fg,
      git_deleted_fg: theme.git.deleted_fg,
      tilde_fg: theme.editor.tilde_fg
    ]
  end

  # ── Scroll region detection ──────────────────────────────────────────────

  @spec detect_scroll_regions(ctx(), Caches.t()) :: [scroll_delta()] | nil
  defp detect_scroll_regions(ctx, caches) do
    if scroll_optimization_enabled?() and scroll_compatible_mode?(ctx, caches) and
         scroll_region_full_width?(ctx) do
      detect_scroll_regions_impl(ctx, caches)
    else
      nil
    end
  end

  @spec scroll_optimization_enabled?() :: boolean()
  defp scroll_optimization_enabled? do
    Application.get_env(:minga, :tui_scroll_optimization, true) == true
  end

  # Modes where content styling changes every frame (selection highlight,
  # search match highlight). Shifted rows would show stale styling.
  @volatile_modes [:visual, :visual_line, :visual_block, :search, :search_prompt]

  # Returns true when the scroll optimization is safe to attempt.
  # Bails out when the editing mode changed since the last frame (stale
  # highlights from the previous mode would persist on shifted rows) or
  # when the current mode has per-frame visual state changes.
  @spec scroll_compatible_mode?(ctx(), Caches.t()) :: boolean()
  defp scroll_compatible_mode?(ctx, caches) do
    current_mode = if ctx.editing, do: ctx.editing.mode, else: nil
    prev_mode = caches.emit_prev_editing_mode

    current_mode not in @volatile_modes and current_mode == prev_mode
  end

  # ANSI scroll regions (CSI top;bottom r) always scroll the full terminal
  # width; there is no column restriction in the spec. When any chrome
  # element occupies columns alongside the editor within the scroll
  # region's row range, the scroll shifts that chrome too, desynchronizing
  # libvaxis's screen buffers from the actual terminal state.
  #
  # If you add a new sidebar or column-sharing chrome element to the
  # layout, extend this guard to include it.
  @spec scroll_region_full_width?(ctx()) :: boolean()
  defp scroll_region_full_width?(ctx) do
    ctx.layout.file_tree == nil
  end

  @spec detect_scroll_regions_impl(ctx(), Caches.t()) :: [scroll_delta()] | nil
  defp detect_scroll_regions_impl(ctx, caches) do
    prev_tops = caches.emit_prev_viewport_tops
    prev_rects = caches.emit_prev_content_rects
    prev_gutter_ws = caches.emit_prev_gutter_ws
    prev_cursor_lines = caches.emit_prev_cursor_lines

    if prev_tops == %{} or prev_rects == %{} or prev_gutter_ws == %{} or prev_cursor_lines == %{} do
      nil
    else
      layout = ctx.layout

      collect_scroll_deltas(
        ctx,
        layout,
        prev_tops,
        prev_rects,
        prev_gutter_ws,
        prev_cursor_lines,
        caches
      )
    end
  end

  @spec collect_scroll_deltas(
          ctx(),
          Layout.t(),
          %{pos_integer() => non_neg_integer()},
          %{pos_integer() => Layout.rect()},
          %{pos_integer() => non_neg_integer()},
          %{pos_integer() => non_neg_integer()},
          Caches.t()
        ) :: [scroll_delta()] | nil
  defp collect_scroll_deltas(
         ctx,
         layout,
         prev_tops,
         prev_rects,
         prev_gutter_ws,
         prev_cursor_lines,
         caches
       ) do
    current_win_ids = MapSet.new(Map.keys(layout.window_layouts))
    prev_win_ids = MapSet.new(Map.keys(prev_tops))

    if current_win_ids != prev_win_ids do
      nil
    else
      prev_versions = caches.emit_prev_buf_versions

      prev = %{
        tops: prev_tops,
        rects: prev_rects,
        gutter_ws: prev_gutter_ws,
        buf_versions: prev_versions,
        cursor_lines: prev_cursor_lines
      }

      deltas =
        Enum.reduce_while(layout.window_layouts, [], fn {win_id, win_layout}, acc ->
          window = Map.get(ctx.windows.map, win_id)
          check_window_scroll(window, win_id, win_layout, prev, acc)
        end)

      case deltas do
        list when is_list(list) and list != [] -> Enum.reverse(list)
        _ -> nil
      end
    end
  end

  @spec check_window_scroll(
          MingaEditor.Window.t() | nil,
          pos_integer(),
          Layout.window_layout(),
          map(),
          list()
        ) :: {:cont, list()} | {:halt, atom()}
  defp check_window_scroll(nil, _win_id, _win_layout, _prev, acc), do: {:cont, acc}

  defp check_window_scroll(window, win_id, win_layout, prev, acc) do
    if match?({:agent_chat, _}, window.content) do
      {:cont, acc}
    else
      compare_window_scroll(window, win_id, win_layout, prev, acc)
    end
  end

  @spec compare_window_scroll(
          MingaEditor.Window.t(),
          pos_integer(),
          Layout.window_layout(),
          map(),
          list()
        ) :: {:cont, list()} | {:halt, atom()}
  defp compare_window_scroll(window, win_id, win_layout, prev, acc) do
    prev_rect = Map.get(prev.rects, win_id)
    current_rect = win_layout.content

    prev_gutter_w = Map.get(prev.gutter_ws, win_id)
    current_gutter_w = window.render_cache.last_gutter_w

    prev_top = Map.get(prev.tops, win_id)
    current_top = window.render_cache.last_viewport_top

    prev_version = Map.get(prev.buf_versions, win_id)
    current_version = window.render_cache.last_buf_version

    prev_cursor_line = Map.get(prev.cursor_lines, win_id)
    current_cursor_line = window.render_cache.last_cursor_line

    classify_scroll_delta(
      %{
        prev_rect: prev_rect,
        cur_rect: current_rect,
        prev_gw: prev_gutter_w,
        cur_gw: current_gutter_w,
        prev_top: prev_top,
        cur_top: current_top,
        prev_ver: prev_version,
        cur_ver: current_version,
        prev_cursor_line: prev_cursor_line,
        cur_cursor_line: current_cursor_line
      },
      win_id,
      acc
    )
  end

  @spec classify_scroll_delta(map(), pos_integer(), list()) ::
          {:cont, list()} | {:halt, atom()}
  defp classify_scroll_delta(%{prev_rect: pr, cur_rect: cr}, _, _) when pr != cr,
    do: {:halt, :layout_changed}

  defp classify_scroll_delta(%{prev_gw: pg, cur_gw: cg}, _, _) when pg != cg,
    do: {:halt, :gutter_changed}

  defp classify_scroll_delta(%{prev_top: pt, cur_top: ct}, _, acc) when pt == ct,
    do: {:cont, acc}

  defp classify_scroll_delta(%{prev_top: pt, cur_top: ct}, _, _)
       when abs(ct - pt) > @max_scroll_delta,
       do: {:halt, :delta_too_large}

  defp classify_scroll_delta(%{prev_ver: pv, cur_ver: cv}, _, _) when pv != cv,
    do: {:halt, :content_changed}

  defp classify_scroll_delta(%{cur_rect: rect, prev_top: pt, cur_top: ct} = params, win_id, acc) do
    {:cont,
     [
       %{
         win_id: win_id,
         delta: ct - pt,
         content_rect: rect,
         redraw_rows: cursorline_redraw_rows(params)
       }
       | acc
     ]}
  end

  @spec cursorline_redraw_rows(map()) :: [non_neg_integer()]
  defp cursorline_redraw_rows(%{cur_top: cur_top, prev_top: prev_top} = params) do
    delta = cur_top - prev_top

    [
      shifted_previous_cursorline_row(params, delta),
      cursorline_screen_row(params.cur_rect, params.cur_cursor_line, cur_top)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec shifted_previous_cursorline_row(map(), integer()) :: non_neg_integer() | nil
  defp shifted_previous_cursorline_row(params, delta) do
    case cursorline_screen_row(params.prev_rect, params.prev_cursor_line, params.prev_top) do
      nil -> nil
      row -> keep_row_in_rect(row - delta, params.cur_rect)
    end
  end

  @spec cursorline_screen_row(Layout.rect() | nil, term(), term()) :: non_neg_integer() | nil
  defp cursorline_screen_row({row, _col, _width, height}, cursor_line, viewport_top)
       when is_integer(cursor_line) and is_integer(viewport_top) do
    rel = cursor_line - viewport_top

    if rel >= 0 and rel < height do
      row + rel
    end
  end

  defp cursorline_screen_row(_rect, _cursor_line, _viewport_top), do: nil

  @spec keep_row_in_rect(integer(), Layout.rect() | nil) :: non_neg_integer() | nil
  defp keep_row_in_rect(row, {top, _col, _width, height}) when row >= top and row < top + height,
    do: row

  defp keep_row_in_rect(_row, _rect), do: nil

  # ── Command building helpers ─────────────────────────────────────────────

  @spec build_scroll_commands([scroll_delta()]) :: [binary()]
  defp build_scroll_commands(scroll_deltas) do
    Enum.map(scroll_deltas, fn %{delta: delta, content_rect: {row, _col, _w, height}} ->
      top_row = row
      bottom_row = row + height - 1
      Protocol.encode_scroll_region(top_row, bottom_row, delta)
    end)
  end

  @doc """
  Collects all chrome draws from a frame for TUI rendering.

  Concatenates tab_bar, file_tree, agentic_view, separators, status_bar,
  agent_panel, minibuffer, and splash draws.
  """
  @spec collect_chrome_draws(Frame.t()) :: [DisplayList.draw()]
  def collect_chrome_draws(frame) do
    frame.tab_bar ++
      frame.file_tree ++
      frame.agentic_view ++
      frame.separators ++
      frame.status_bar ++
      frame.agent_panel ++
      frame.minibuffer ++
      (frame.splash || [])
  end

  @doc """
  Collects all overlay draws from a frame, flattening overlay draw lists.
  """
  @spec collect_overlay_draws(Frame.t()) :: [DisplayList.draw()]
  def collect_overlay_draws(frame) do
    Enum.flat_map(frame.overlays, fn %Overlay{draws: draws} -> draws end)
  end

  @spec collect_new_content_draws(Frame.t(), [scroll_delta()]) :: [DisplayList.draw()]
  defp collect_new_content_draws(frame, scroll_deltas) do
    rows_to_redraw = redraw_ranges(scroll_deltas)

    Enum.flat_map(frame.windows, fn wf ->
      filter_window_draws_for_new_rows(wf, rows_to_redraw)
    end)
  end

  @doc """
  Computes which rows are newly revealed after a scroll delta.

  For a positive delta (scrolled down), the new rows are at the bottom.
  For a negative delta (scrolled up), the new rows are at the top.
  """
  @spec compute_new_rows(scroll_delta()) :: Range.t()
  def compute_new_rows(%{delta: delta, content_rect: {row, _col, _w, height}}) do
    if delta > 0 do
      bottom = row + height - 1
      (bottom - delta + 1)..bottom
    else
      row..(row + abs(delta) - 1)
    end
  end

  @spec redraw_ranges([scroll_delta()]) :: [Range.t()]
  defp redraw_ranges(scroll_deltas) do
    Enum.flat_map(scroll_deltas, fn delta ->
      [compute_new_rows(delta) | cursorline_redraw_ranges(Map.get(delta, :redraw_rows, []))]
    end)
  end

  @spec cursorline_redraw_ranges([non_neg_integer()]) :: [Range.t()]
  defp cursorline_redraw_ranges(rows) do
    Enum.map(rows, fn row -> row..row end)
  end

  @spec filter_window_draws_for_new_rows(WindowFrame.t(), [Range.t()]) :: [DisplayList.draw()]
  defp filter_window_draws_for_new_rows(wf, all_new_rows) do
    gutter = filter_layer_by_ranges(wf.gutter, all_new_rows)
    lines = filter_layer_by_ranges(wf.lines, all_new_rows)
    tildes = filter_layer_by_ranges(wf.tilde_lines, all_new_rows)

    gutter ++ lines ++ tildes
  end

  @doc """
  Filters a render layer to only include rows that fall within the given ranges.

  Used by scroll region optimization to extract only newly revealed content.
  """
  @spec filter_layer_by_ranges(DisplayList.render_layer(), [Range.t()]) :: [DisplayList.draw()]
  def filter_layer_by_ranges(layer, ranges) do
    layer
    |> Enum.filter(fn {row, _runs} -> Enum.any?(ranges, fn r -> row in r end) end)
    |> Enum.flat_map(fn {row, runs} ->
      Enum.map(runs, fn {col, text, style} -> {row, col, text, style} end)
    end)
  end
end
