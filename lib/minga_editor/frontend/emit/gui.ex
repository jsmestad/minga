defmodule MingaEditor.Frontend.Emit.GUI do
  @moduledoc """
  GUI-specific emit logic for the Emit stage.

  Handles two responsibilities:

  1. **Frame filtering**: strips SwiftUI-owned chrome fields from the
     display list frame before it's converted to Metal cell-grid commands.
     Tab bar, file tree, agent panel, agentic view, status bar, and splash
     are handled natively by SwiftUI and should not appear in the cell grid.
     Gutter is also stripped from window frames since the GUI renders it
     natively.

  2. **Chrome synchronization**: sends structured chrome data (tab bar,
     file tree, which-key, completion, breadcrumb, status bar, picker,
     agent chat, theme) to the native GUI frontend via dedicated protocol
     opcodes. These are separate from the cell-grid rendering commands.

  Called from `Emit.emit/3` only when the frontend has GUI capabilities.
  """

  alias Minga.Buffer
  alias Minga.Config

  alias MingaEditor.DisplayList.Frame
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Shell.Traditional.Chrome.Helpers, as: ChromeHelpers
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.Viewport
  alias MingaEditor.Window.Content
  alias MingaEditor.Frontend.Emit.Context

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @typedoc "Emit context for the GUI stage."
  @type ctx :: Context.t()

  # ── Frame filtering ──────────────────────────────────────────────────────

  @doc """
  Filters a frame for GUI rendering.

  Most chrome fields are already empty from Chrome.GUI (tab bar, file tree,
  status bar, separators, minibuffer, overlays all use dedicated GUI opcodes).
  This filter handles the two remaining sources of draw_text content:

  1. **Splash screen** draws come from `Renderer`, not Chrome. Cleared here
     since the GUI could render a native splash.
  2. **Window content** (gutter, lines, tilde_lines) for buffer windows with
     semantic data (0x80 opcode). Gutter is cleared for all windows since the
     GUI renders it natively via 0x7B.
  """
  @spec filter_frame_for_gui(Frame.t()) :: Frame.t()
  def filter_frame_for_gui(frame) do
    %{
      frame
      | splash: nil,
        windows:
          Enum.map(frame.windows, fn wf ->
            # Buffer windows with semantic content get their text from the
            # 0x80 opcode, not draw_text. Strip lines + tilde_lines.
            # Agent chat windows don't have semantic content and keep their draws.
            if wf.semantic != nil do
              %{wf | gutter: %{}, lines: %{}, tilde_lines: %{}}
            else
              %{wf | gutter: %{}}
            end
          end)
    }
  end

  # ── Chrome synchronization ──────────────────────────────────────────────

  @doc """
  Builds Metal-critical chrome commands that must be bundled with the
  main frame for atomic delivery.

  These commands write to LineBuffer state (gutter, cursorline, gutter
  separator) which the Metal render pass reads. If they arrive in a
  separate port message after `batch_end`, vsync can fire between them,
  causing blank or partially rendered frames.

  Returns encoded command binaries for the caller to bundle with the
  main frame commands before `batch_end`.
  """
  @spec build_metal_commands(ctx()) :: [binary()]
  def build_metal_commands(ctx) do
    build_gui_gutter_commands(ctx) ++
      build_gui_cursorline_commands(ctx) ++
      build_gui_gutter_separator_commands(ctx) ++
      build_gui_split_separator_commands(ctx) ++
      build_gui_indent_guide_commands(ctx)
  end

  @doc """
  Sends SwiftUI chrome data to the native frontend.

  These update `@Observable` properties on SwiftUI state objects
  (tab bar, file tree, status bar, picker, etc.). SwiftUI coalesces its
  own view updates independently of Metal vsync, so these are safe to
  send as separate port messages after the atomic Metal frame.

  Each chrome component uses fingerprint-based change detection via the
  `Caches` struct to skip re-encoding and re-sending when nothing changed.
  During j/k scroll, only the status bar (cursor position) changes;
  everything else is skipped. All changed chrome commands are batched into
  a single `MingaEditor.Frontend.send_commands` call to reduce port write
  overhead.

  `status_bar_data` and `minibuffer_data` are accepted for API compatibility
  but no longer used here; both are now handled by the RenderModel adapter path.
  """
  @spec sync_swiftui_chrome(ctx(), term(), term(), Caches.t()) ::
          {ctx(), Caches.t()}
  def sync_swiftui_chrome(ctx, _status_bar_data, _minibuffer_data, caches) do
    # Use map_reduce to thread caches through each builder function.
    # Each build_gui_* function returns {cmd | nil, updated_caches}.
    # Note: status_bar is now handled by the RenderModel adapter path.
    builders = [
      &build_gui_hover_popup_cmd/2,
      &build_gui_float_popup_cmd/2,
      &build_gui_change_summary_cmd/2,
      &build_gui_edit_timeline_cmd/2,
      &build_gui_extension_overlay_cmd/2,
      &build_gui_extension_panel_cmd/2
    ]

    {cmds, caches} =
      Enum.map_reduce(builders, caches, fn build_fn, acc_caches ->
        build_fn.(ctx, acc_caches)
      end)

    chrome_cmds = Enum.reject(cmds, &is_nil/1)

    # Bottom panel is special: it also returns updated ctx (for message_store).
    {panel_cmd, ctx, caches} = build_gui_bottom_panel_cmd(ctx, caches)
    chrome_cmds = if panel_cmd, do: chrome_cmds ++ [panel_cmd], else: chrome_cmds

    if chrome_cmds != [] do
      MingaEditor.Frontend.send_commands(ctx.port_manager, chrome_cmds)
    end

    {ctx, caches}
  end

  # ── Completion, Status bar, Minibuffer ──
  # (All now handled by the RenderModel adapter path)

  @spec active_buffer_path(ctx()) :: String.t() | nil
  defp active_buffer_path(ctx) do
    case ctx.buffers.active do
      nil -> nil
      buf -> Buffer.file_path(buf)
    end
  end

  # ── Gutter separator ──

  @spec build_gui_gutter_separator_commands(ctx()) :: [binary()]
  defp build_gui_gutter_separator_commands(ctx) do
    show? = Config.get(:show_gutter_separator)
    active_window = Map.get(ctx.windows.map, ctx.windows.active)
    gutter_w = if active_window, do: active_window.render_cache.last_gutter_w, else: 0

    # Only send separator when enabled, visible gutter (gutter_w > 0).
    # Use the theme's gutter separator color, falling back to gutter fg.
    # Theme colors are already 24-bit RGB integers.
    {col, color_rgb} =
      if show? and gutter_w > 0 do
        color = ctx.theme.gutter.separator_fg || ctx.theme.gutter.fg
        {gutter_w, color}
      else
        {0, 0}
      end

    [ProtocolGUI.encode_gui_gutter_separator(max(col, 0), color_rgb)]
  end

  # ── Cursorline ──

  @spec build_gui_cursorline_commands(ctx()) :: [binary()]
  defp build_gui_cursorline_commands(ctx) do
    active_window = Map.get(ctx.windows.map, ctx.windows.active)
    cursorline_enabled = Config.get(:cursorline)

    {row, bg_rgb} =
      if active_window && cursorline_enabled do
        # Compute screen row of cursor: content_rect row + (cursor_line - viewport_top)
        layout = ctx.layout

        case Map.get(layout.window_layouts, ctx.windows.active) do
          %{content: {content_row, _col, _w, _h}} ->
            cursor_line = active_window.render_cache.last_cursor_line || 0
            viewport_top = active_window.render_cache.last_viewport_top || 0
            screen_row = content_row + cursor_line - viewport_top
            bg = ctx.theme.editor.cursorline_bg || 0
            {screen_row, bg}

          nil ->
            {0xFFFF, 0}
        end
      else
        {0xFFFF, 0}
      end

    [ProtocolGUI.encode_gui_cursorline(row, bg_rgb)]
  end

  # ── Gutter ──

  @spec build_gui_gutter_commands(ctx()) :: [binary()]
  defp build_gui_gutter_commands(ctx) do
    layout = ctx.layout

    window_gutters =
      Enum.flat_map(layout.window_layouts, fn {win_id, win_layout} ->
        window = Map.get(ctx.windows.map, win_id)

        # Skip agent chat windows (they don't have gutter)
        if window && is_pid(window.buffer) && !Content.agent_chat?(window.content) do
          is_active = win_id == ctx.windows.active
          gutter_data = build_window_gutter(window, win_id, win_layout, is_active)
          [ProtocolGUI.encode_gui_gutter(gutter_data)]
        else
          []
        end
      end)

    window_gutters
  end

  # Builds a minimal gutter entry for the agent prompt SemanticWindow.
  # Positions it at the bottom of the grid with no line numbers or sign column.
  @spec build_window_gutter(
          MingaEditor.Window.t(),
          pos_integer(),
          Layout.window_layout(),
          boolean()
        ) :: ProtocolGUI.gutter_data()
  defp build_window_gutter(window, win_id, win_layout, is_active) do
    buf = window.buffer
    cursor_line = max(window.render_cache.last_cursor_line, 0)
    viewport_top = max(window.render_cache.last_viewport_top, 0)
    line_count = max(window.render_cache.last_line_count, 0)

    {content_row, content_col, content_w, content_height} = win_layout.content

    win_pos = %{
      window_id: win_id,
      content_row: content_row,
      content_col: content_col,
      content_height: content_height,
      content_width: content_w,
      is_active: is_active
    }

    # Guard against uninitialized window state (before first render)
    if line_count == 0 do
      Map.merge(win_pos, %{
        cursor_line: 0,
        line_number_style: :none,
        line_number_width: 0,
        sign_col_width: 0,
        entries: []
      })
    else
      build_gutter_entries(window, buf, win_pos, %{
        cursor_line: cursor_line,
        viewport_top: viewport_top,
        line_count: line_count,
        content_w: content_w
      })
    end
  end

  @spec build_gutter_entries(MingaEditor.Window.t(), pid(), map(), map()) ::
          ProtocolGUI.gutter_data()
  defp build_gutter_entries(window, buf, win_pos, params) do
    %{
      cursor_line: cursor_line,
      viewport_top: viewport_top,
      line_count: line_count,
      content_w: content_w
    } = params

    line_number_style = Buffer.get_option(buf, :line_numbers)

    # The native gutter keeps fold indicators in a dedicated cell after the sign column.
    sign_col_width =
      MingaEditor.Renderer.Gutter.sign_column_width() +
        MingaEditor.Renderer.Gutter.fold_column_width()

    line_number_width =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    # Get signs and decorations for the buffer
    decorations = Buffer.decorations(buf)
    diag_signs = ContentHelpers.diagnostic_signs_for_window(window)
    git_signs = ContentHelpers.git_signs_for_window(window)
    fold_start_lines = MapSet.new(window.fold_ranges, & &1.start_line)

    fold_end_by_start =
      Map.new(window.fold_ranges, fn range -> {range.start_line, range.end_line} end)

    content_width = max(content_w - sign_col_width - line_number_width, 1)

    entries =
      window
      |> gui_gutter_visible_entries(
        decorations,
        viewport_top,
        win_pos.content_height,
        line_count,
        content_width
      )
      |> Enum.map(fn
        {buf_line, row_type} when buf_line < line_count ->
          resolve_gutter_entry(
            buf_line,
            row_type,
            fold_start_lines,
            fold_end_by_start,
            diag_signs,
            git_signs,
            decorations
          )

        {buf_line, _row_type} ->
          %{
            buf_line: buf_line,
            display_type: :normal,
            sign_type: :none,
            fold_end_line: 0xFFFF_FFFF
          }
      end)

    Map.merge(win_pos, %{
      cursor_line: cursor_line,
      line_number_style: line_number_style,
      line_number_width: line_number_width,
      sign_col_width: sign_col_width,
      entries: entries
    })
  end

  @spec gui_gutter_visible_entries(
          MingaEditor.Window.t(),
          Minga.Core.Decorations.t(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: [{non_neg_integer(), term()}]
  defp gui_gutter_visible_entries(
         window,
         decorations,
         viewport_top,
         content_height,
         line_count,
         content_width
       ) do
    first_line = gui_gutter_first_line(window.fold_map, viewport_top)

    case DisplayMap.compute(
           window.fold_map,
           decorations,
           first_line,
           content_height,
           line_count,
           content_width
         ) do
      nil -> Enum.map(0..(content_height - 1), fn row -> {viewport_top + row, :normal} end)
      %DisplayMap{} = dm -> DisplayMap.to_visible_line_map(dm)
    end
  end

  @spec gui_gutter_first_line(FoldMap.t(), non_neg_integer()) :: non_neg_integer()
  defp gui_gutter_first_line(%FoldMap{folds: []}, viewport_top), do: viewport_top

  defp gui_gutter_first_line(%FoldMap{} = fold_map, viewport_top),
    do: FoldMap.visible_to_buffer(fold_map, viewport_top)

  # Resolves the gutter entry for a buffer line. Diagnostics > git signs > annotations.
  @spec resolve_gutter_entry(
          non_neg_integer(),
          term(),
          MapSet.t(non_neg_integer()),
          %{non_neg_integer() => non_neg_integer()},
          %{non_neg_integer() => atom()},
          %{non_neg_integer() => atom()},
          Minga.Core.Decorations.t()
        ) :: ProtocolGUI.gutter_entry()
  defp resolve_gutter_entry(
         buf_line,
         row_type,
         fold_start_lines,
         fold_end_by_start,
         diag_signs,
         git_signs,
         decorations
       ) do
    sign_type = resolve_sign_type(buf_line, diag_signs, git_signs)
    display_type = resolve_display_type(row_type, fold_start_lines, buf_line)
    fold_end_line = Map.get(fold_end_by_start, buf_line, 0xFFFF_FFFF)

    case sign_type do
      :none ->
        resolve_annotation_entry(buf_line, display_type, fold_end_line, decorations)

      _ ->
        %{
          buf_line: buf_line,
          display_type: display_type,
          sign_type: sign_type,
          fold_end_line: fold_end_line
        }
    end
  end

  @spec resolve_display_type(term(), MapSet.t(non_neg_integer()), non_neg_integer()) ::
          ProtocolGUI.display_type()
  defp resolve_display_type({:fold_start, _hidden}, _fold_start_lines, _buf_line), do: :fold_start

  defp resolve_display_type({:decoration_fold, _fold}, _fold_start_lines, _buf_line),
    do: :fold_start

  defp resolve_display_type(:normal, fold_start_lines, buf_line) do
    if MapSet.member?(fold_start_lines, buf_line), do: :fold_open, else: :normal
  end

  defp resolve_display_type(_row_type, _fold_start_lines, _buf_line), do: :normal

  # Checks for :gutter_icon annotations when no diagnostic or git sign is present.
  @spec resolve_annotation_entry(
          non_neg_integer(),
          ProtocolGUI.display_type(),
          non_neg_integer(),
          Minga.Core.Decorations.t()
        ) ::
          ProtocolGUI.gutter_entry()
  defp resolve_annotation_entry(buf_line, display_type, fold_end_line, decorations) do
    icons =
      decorations
      |> Minga.Core.Decorations.annotations_for_line(buf_line)
      |> Enum.filter(fn ann -> ann.kind == :gutter_icon end)

    case icons do
      [] ->
        %{
          buf_line: buf_line,
          display_type: display_type,
          sign_type: :none,
          fold_end_line: fold_end_line
        }

      [ann | _] ->
        %{
          buf_line: buf_line,
          display_type: display_type,
          sign_type: :annotation,
          fold_end_line: fold_end_line,
          sign_fg: ann.fg,
          sign_text: String.slice(ann.text, 0, 2)
        }
    end
  end

  # Resolves the highest-priority sign for a buffer line.
  # Diagnostics take priority over git signs (same as Renderer.Gutter).
  @spec resolve_sign_type(
          non_neg_integer(),
          %{non_neg_integer() => atom()},
          %{non_neg_integer() => atom()}
        ) :: ProtocolGUI.sign_type()
  defp resolve_sign_type(buf_line, diag_signs, git_signs) do
    case Map.get(diag_signs, buf_line) do
      :error -> :diag_error
      :warning -> :diag_warning
      :info -> :diag_info
      :hint -> :diag_hint
      nil -> resolve_git_sign(buf_line, git_signs)
    end
  end

  @spec resolve_git_sign(non_neg_integer(), %{non_neg_integer() => atom()}) ::
          ProtocolGUI.sign_type()
  defp resolve_git_sign(buf_line, git_signs) do
    case Map.get(git_signs, buf_line) do
      :added -> :git_added
      :modified -> :git_modified
      :deleted -> :git_deleted
      _ -> :none
    end
  end

  # ── Hover popup ──

  @spec build_gui_hover_popup_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_hover_popup_cmd(%{shell_state: %{hover_popup: popup}}, caches) do
    fp = :erlang.phash2(popup)

    if fp != caches.last_gui_hover_popup_fp do
      {ProtocolGUI.encode_gui_hover_popup(popup), %{caches | last_gui_hover_popup_fp: fp}}
    else
      {nil, caches}
    end
  end

  # ── Split separators ──

  @spec build_gui_split_separator_commands(ctx()) :: [binary()]
  defp build_gui_split_separator_commands(ctx) do
    if MingaEditor.State.Windows.split?(ctx.windows) do
      layout = ctx.layout
      border_color = ctx.theme.editor.split_border_fg

      # Collect vertical separators from the window tree
      verticals =
        ChromeHelpers.collect_vertical_separators(
          ctx.windows.tree,
          layout.editor_area
        )

      # Horizontal separators from layout
      horizontals = layout.horizontal_separators

      [ProtocolGUI.encode_gui_split_separators(border_color, verticals, horizontals)]
    else
      # No splits: send empty separator data to clear any previous state
      [ProtocolGUI.encode_gui_split_separators(0, [], [])]
    end
  end

  # ── Float popup ──

  @spec build_gui_float_popup_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_float_popup_cmd(
         %{shell_state: %{observatory_inspection: %{visible: true} = data}},
         caches
       ) do
    fp = :erlang.phash2({:observatory_inspection, data})

    if fp != caches.last_gui_float_popup_fp do
      {ProtocolGUI.encode_gui_float_popup(data), %{caches | last_gui_float_popup_fp: fp}}
    else
      {nil, caches}
    end
  end

  defp build_gui_float_popup_cmd(ctx, caches) do
    float_window = find_float_popup_window(ctx)

    fp = float_popup_fingerprint(ctx, float_window)

    if fp != caches.last_gui_float_popup_fp do
      cmd =
        if float_window do
          data = build_float_popup_data(ctx, float_window)
          ProtocolGUI.encode_gui_float_popup(data)
        else
          ProtocolGUI.encode_gui_float_popup(%{
            visible: false,
            title: "",
            lines: [],
            width: 0,
            height: 0
          })
        end

      {cmd, %{caches | last_gui_float_popup_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec float_popup_fingerprint(ctx(), MingaEditor.Window.t() | nil) :: integer()
  defp float_popup_fingerprint(_ctx, nil), do: :erlang.phash2(nil)

  defp float_popup_fingerprint(ctx, window) do
    rule = window.popup_meta.rule
    vp = ctx.viewport
    width = resolve_float_dim(rule, :width, vp.cols)
    height = resolve_float_dim(rule, :height, vp.rows)

    buffer_fp =
      try do
        {Buffer.buffer_name(window.buffer), Buffer.version(window.buffer)}
      catch
        :exit, _ -> :dead
      end

    :erlang.phash2({window.buffer, window.popup_meta, width, height, buffer_fp})
  end

  @spec find_float_popup_window(ctx()) :: MingaEditor.Window.t() | nil
  defp find_float_popup_window(ctx) do
    Enum.find_value(ctx.windows.map, fn
      {_id,
       %{
         popup_meta: %MingaEditor.UI.Popup.Active{
           rule: %Minga.Popup.Rule{display: :float}
         }
       } = w} ->
        w

      _ ->
        nil
    end)
  end

  @spec build_float_popup_data(ctx(), MingaEditor.Window.t()) :: ProtocolGUI.float_popup_data()
  defp build_float_popup_data(ctx, window) do
    rule = window.popup_meta.rule
    vp = ctx.viewport

    width = resolve_float_dim(rule, :width, vp.cols)
    height = resolve_float_dim(rule, :height, vp.rows)

    # Interior dimensions (subtract 2 for border)
    interior_h = max(height - 2, 1)
    interior_w = max(width - 2, 1)

    {title, lines} =
      try do
        name = Buffer.buffer_name(window.buffer)
        snapshot = Buffer.render_snapshot(window.buffer, 0, interior_h)
        trimmed = Enum.map(snapshot.lines, &String.slice(&1, 0, interior_w))
        {name, trimmed}
      catch
        :exit, _ -> {"", []}
      end

    %{visible: true, title: title, lines: lines, width: width, height: height}
  end

  @spec resolve_float_dim(Minga.Popup.Rule.t(), :width | :height, pos_integer()) ::
          pos_integer()
  defp resolve_float_dim(rule, dim, viewport_size) do
    val =
      case dim do
        :width -> rule.width || rule.size || {:percent, 50}
        :height -> rule.height || rule.size || {:percent, 50}
      end

    case val do
      {:percent, pct} -> max(div(viewport_size * pct, 100), 1)
      {:cols, n} -> n
      {:rows, n} -> n
      n when is_integer(n) -> n
      _ -> max(div(viewport_size, 2), 1)
    end
  end

  # ── Bottom panel ──

  # Bottom panel is special: it returns {cmd | nil, updated_ctx, updated_caches} because
  # encode_gui_bottom_panel may advance the message_store cursor when new
  # entries have arrived. We still fingerprint to skip encoding when the
  # panel hasn't changed.
  @spec build_gui_bottom_panel_cmd(ctx(), Caches.t()) :: {binary() | nil, ctx(), Caches.t()}
  defp build_gui_bottom_panel_cmd(
         %{shell_state: %{bottom_panel: panel}, message_store: store} = ctx,
         caches
       ) do
    fp = :erlang.phash2({panel, store})

    if fp != caches.last_gui_bottom_panel_fp do
      {cmd, new_store} = ProtocolGUI.encode_gui_bottom_panel(panel, store)
      {cmd, %{ctx | message_store: new_store}, %{caches | last_gui_bottom_panel_fp: fp}}
    else
      {nil, ctx, caches}
    end
  end

  # ── Change Summary ──

  @spec build_gui_change_summary_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}

  # Change summary visible when zoomed into an agent card (not You card)
  defp build_gui_change_summary_cmd(%{shell: shell} = ctx, caches) do
    case shell.gui_payload(ctx) do
      {:board, %{zoomed_card_id: card_id}} when card_id != nil ->
        build_gui_change_summary_for_board_card(card_id, caches)

      _other ->
        hide_gui_change_summary(caches)
    end
  end

  @spec build_gui_change_summary_for_board_card(pos_integer(), Caches.t()) ::
          {binary() | nil, Caches.t()}
  defp build_gui_change_summary_for_board_card(card_id, caches) do
    # TODO: Compute diff stats from the card's touched files
    # For now, send empty list to test the UI
    entries = []
    selected_index = 0

    fp = :erlang.phash2({card_id, entries})

    if fp != caches.last_gui_change_summary_fp do
      {ProtocolGUI.encode_gui_change_summary(entries, selected_index),
       %{caches | last_gui_change_summary_fp: fp}}
    else
      {nil, caches}
    end
  end

  # Board grid or other shells: hide change summary
  @spec hide_gui_change_summary(Caches.t()) :: {binary() | nil, Caches.t()}
  defp hide_gui_change_summary(caches) do
    if caches.last_gui_change_summary_fp != :hidden do
      {ProtocolGUI.encode_gui_change_summary([], 0),
       %{caches | last_gui_change_summary_fp: :hidden}}
    else
      {nil, caches}
    end
  end

  # ── Edit timeline ──

  alias MingaEditor.Agent.EditTimeline

  @spec build_gui_edit_timeline_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_edit_timeline_cmd(ctx, caches) do
    timeline = ctx.agent_ui.view.edit_timeline
    path = active_buffer_path(ctx)

    if path != nil and EditTimeline.has_entries?(timeline, path) do
      entries = EditTimeline.entries_for(timeline, path)
      viewing = EditTimeline.viewing_index(timeline, path)

      first_ts =
        case entries do
          [%{timestamp: ts} | _] -> ts
          _ -> 0
        end

      wire_entries =
        Enum.map(entries, fn entry ->
          %{
            index: entry.index,
            tool_name: entry.tool_name,
            timestamp_delta: abs(entry.timestamp - first_ts)
          }
        end)

      fp = :erlang.phash2({path, length(entries), viewing, Enum.map(entries, & &1.tool_name)})

      if fp != caches.last_gui_edit_timeline_fp do
        {ProtocolGUI.encode_gui_edit_timeline(true, viewing, wire_entries),
         %{caches | last_gui_edit_timeline_fp: fp}}
      else
        {nil, caches}
      end
    else
      if caches.last_gui_edit_timeline_fp != :hidden do
        {ProtocolGUI.encode_gui_edit_timeline(false, nil, []),
         %{caches | last_gui_edit_timeline_fp: :hidden}}
      else
        {nil, caches}
      end
    end
  end

  # ── Extension Overlays ──

  @spec build_gui_extension_overlay_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_extension_overlay_cmd(ctx, caches) do
    overlay_entries = build_extension_overlay_entries(ctx)
    fp = :erlang.phash2(overlay_entries)

    if fp != caches.last_gui_extension_overlays_fp do
      cmd = ProtocolGUI.encode_gui_extension_overlays(overlay_entries)
      {cmd, %{caches | last_gui_extension_overlays_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec build_extension_overlay_entries(ctx()) :: [ProtocolGUI.extension_overlay_entry()]
  defp build_extension_overlay_entries(ctx) do
    overlays = Minga.Extension.Overlay.all()

    if overlays == [] do
      []
    else
      Enum.flat_map(overlays, &resolve_overlay_to_entries(&1, ctx))
    end
  end

  @spec resolve_overlay_to_entries(Minga.Extension.Overlay.entry(), ctx()) ::
          [ProtocolGUI.extension_overlay_entry()]
  defp resolve_overlay_to_entries(overlay, ctx) do
    Enum.flat_map(ctx.layout.window_layouts, fn {win_id, win_layout} ->
      window = Map.get(ctx.windows.map, win_id)
      maybe_overlay_entry(overlay, window, win_id, win_layout)
    end)
  end

  @spec maybe_overlay_entry(
          Minga.Extension.Overlay.entry(),
          term(),
          pos_integer(),
          Layout.window_layout()
        ) :: [ProtocolGUI.extension_overlay_entry()]
  defp maybe_overlay_entry(overlay, %{buffer: buf} = window, win_id, win_layout)
       when is_pid(buf) do
    if buf == overlay.buffer do
      viewport_top = max(window.render_cache.last_viewport_top, 0)
      {_row, _col, _w, content_height} = win_layout.content
      {line, col} = overlay.position
      row = line - viewport_top

      if row >= 0 and row < content_height do
        style = overlay.style

        [
          %{
            extension: to_string(overlay.extension),
            overlay_id: to_string(overlay.overlay_id),
            window_id: win_id,
            row: row,
            col: col,
            shape: ProtocolGUI.overlay_shape_byte(overlay.shape),
            fg: Map.get(style, :fg, 0x51AFEF),
            opacity: Map.get(style, :opacity, 102),
            content: overlay.content
          }
        ]
      else
        []
      end
    else
      []
    end
  end

  defp maybe_overlay_entry(_overlay, _window, _win_id, _win_layout), do: []

  # ── Extension Panels ──

  @spec build_gui_extension_panel_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_extension_panel_cmd(_ctx, caches) do
    panels = Minga.Extension.Panel.visible()
    fp = :erlang.phash2(panels)

    if fp != caches.last_gui_extension_panels_fp do
      cmd = ProtocolGUI.encode_gui_extension_panels(panels)
      {cmd, %{caches | last_gui_extension_panels_fp: fp}}
    else
      {nil, caches}
    end
  end

  # ── Indent guides ──

  @spec build_gui_indent_guide_commands(ctx()) :: [binary()]
  defp build_gui_indent_guide_commands(ctx) do
    indent_guides_enabled? =
      try do
        Config.get(:indent_guides)
      catch
        :exit, _ -> true
      end

    if indent_guides_enabled? do
      layout = ctx.layout
      windows = ctx.windows.map

      Enum.flat_map(layout.window_layouts, fn {win_id, win_layout} ->
        build_indent_guide_for_window(Map.get(windows, win_id), win_id, win_layout)
      end)
    else
      []
    end
  end

  @spec build_indent_guide_for_window(
          MingaEditor.Window.t() | nil,
          pos_integer(),
          Layout.window_layout()
        ) ::
          [binary()]
  defp build_indent_guide_for_window(nil, win_id, _layout), do: return_empty_guides(win_id)

  defp build_indent_guide_for_window(window, win_id, win_layout) do
    if is_pid(window.buffer) && !Content.agent_chat?(window.content) do
      {_cr, _cc, _cw, content_height} = win_layout.content
      build_window_indent_guides(window, win_id, content_height)
    else
      return_empty_guides(win_id)
    end
  end

  @spec build_window_indent_guides(MingaEditor.Window.t(), pos_integer(), non_neg_integer()) ::
          [binary()]
  defp build_window_indent_guides(window, win_id, content_height) do
    buf = window.buffer
    viewport_top = max(window.render_cache.last_viewport_top, 0)
    line_count = max(window.render_cache.last_line_count, 0)
    visible_count = min(content_height, max(line_count - viewport_top, 0))

    if visible_count <= 0 or line_count == 0 do
      return_empty_guides(win_id)
    else
      compute_and_encode_guides(window, win_id, buf, viewport_top, visible_count)
    end
  end

  @spec compute_and_encode_guides(
          MingaEditor.Window.t(),
          pos_integer(),
          pid(),
          non_neg_integer(),
          pos_integer()
        ) ::
          [binary()]
  defp compute_and_encode_guides(window, win_id, buf, viewport_top, visible_count) do
    {_cursor_line, cursor_col} = window.cursor

    tab_width =
      try do
        Buffer.get_option(buf, :tab_width)
      catch
        :exit, _ -> 2
      end

    lines =
      try do
        Buffer.lines(buf, viewport_top, visible_count)
      catch
        :exit, _ -> []
      end

    {guides, indent_levels} =
      Minga.Core.IndentGuide.compute_with_levels(lines, tab_width, cursor_col)

    encode_guides(guides, win_id, tab_width, indent_levels)
  end

  @spec encode_guides(
          [Minga.Core.IndentGuide.guide()],
          pos_integer(),
          pos_integer(),
          [non_neg_integer()]
        ) ::
          [binary()]
  defp encode_guides([], win_id, _tab_width, _indent_levels), do: return_empty_guides(win_id)

  defp encode_guides(guides, win_id, tab_width, indent_levels) do
    active_guide = Enum.find(guides, fn g -> g.active end)
    active_col = if active_guide, do: active_guide.col, else: 0xFFFF

    guide_data = %{
      window_id: win_id,
      tab_width: tab_width,
      active_guide_col: active_col,
      guide_cols: Enum.map(guides, & &1.col),
      line_indent_levels: indent_levels
    }

    [ProtocolGUI.encode_gui_indent_guides(guide_data)]
  end

  @spec return_empty_guides(pos_integer()) :: [binary()]
  defp return_empty_guides(win_id), do: [ProtocolGUI.encode_gui_indent_guides_empty(win_id)]
end
