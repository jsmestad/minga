defmodule Minga.Editor.RenderPipeline.Emit do
  @moduledoc """
  Stage 7: Emit.

  Converts the composed `Frame` into protocol command binaries and
  sends them to the Zig renderer port. Also sends title and window
  background color when they change (side-channel writes).

  ## Scroll region optimization

  When the viewport shifts by 1-3 lines between frames and no structural
  changes occurred (layout, gutter width, window set), the emit stage
  sends a `scroll_region` command instead of a full `clear + redraw`.
  The terminal emulator shifts its internal buffer, then only the newly
  revealed lines are drawn. This eliminates the majority of cell writes
  for the most common scroll case (Ctrl-e/y, mouse wheel, cursor near edges).
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Frame, Overlay, WindowFrame}
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Title
  alias Minga.Filetype
  alias Minga.Git
  alias Minga.Port.Capabilities
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol
  alias Minga.Telemetry

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Scroll delta info for one window."
  @type scroll_delta :: %{
          win_id: pos_integer(),
          delta: integer(),
          content_rect: Layout.rect()
        }

  # Maximum viewport delta for scroll region optimization.
  @max_scroll_delta 3

  @doc """
  Converts the frame to protocol command binaries and sends them to
  the Zig port. Uses scroll region optimization when possible.

  Also sends title and window background color when they change
  (side-channel writes).
  """
  @spec emit(Frame.t(), state()) :: :ok
  def emit(frame, state) do
    scroll_deltas = detect_scroll_regions(state)
    commands = build_commands(frame, scroll_deltas)
    update_tracking(state)

    byte_count = IO.iodata_length(commands)

    Telemetry.span([:minga, :port, :emit], %{byte_count: byte_count}, fn ->
      PortManager.send_commands(state.port_manager, commands)
      send_title(state)
      send_window_bg(state)
      send_gui_theme(state)
      send_gui_tab_bar(state)
      send_gui_file_tree(state)
      send_gui_which_key(state)
      send_gui_completion(state)
      send_gui_breadcrumb(state)
      send_gui_status_bar(state)
      :ok
    end)
  end

  # ── Scroll region detection ──────────────────────────────────────────────

  @spec detect_scroll_regions(state()) :: [scroll_delta()] | nil
  defp detect_scroll_regions(state) do
    # Scroll region optimization disabled: the interaction between ANSI
    # scroll regions, libvaxis internal buffer sync, and partial content
    # redraws causes content corruption on shifted rows. Full redraw on
    # every frame until this is properly debugged.
    if scroll_optimization_enabled?() do
      detect_scroll_regions_impl(state)
    else
      nil
    end
  end

  # Kill switch for the scroll region optimization. Set to true to re-enable
  # once the libvaxis buffer sync issue is resolved.
  @spec scroll_optimization_enabled?() :: boolean()
  defp scroll_optimization_enabled?, do: false

  @spec detect_scroll_regions_impl(state()) :: [scroll_delta()] | nil
  defp detect_scroll_regions_impl(state) do
    prev_tops = Process.get(:emit_prev_viewport_tops)
    prev_rects = Process.get(:emit_prev_content_rects)
    prev_gutter_ws = Process.get(:emit_prev_gutter_ws)

    # First frame or no previous data: full redraw
    if is_nil(prev_tops) or is_nil(prev_rects) or is_nil(prev_gutter_ws) do
      nil
    else
      layout = Layout.get(state)
      collect_scroll_deltas(state, layout, prev_tops, prev_rects, prev_gutter_ws)
    end
  end

  @spec collect_scroll_deltas(
          state(),
          Layout.t(),
          %{pos_integer() => non_neg_integer()},
          %{pos_integer() => Layout.rect()},
          %{pos_integer() => non_neg_integer()}
        ) :: [scroll_delta()] | nil
  defp collect_scroll_deltas(state, layout, prev_tops, prev_rects, prev_gutter_ws) do
    current_win_ids = MapSet.new(Map.keys(layout.window_layouts))
    prev_win_ids = MapSet.new(Map.keys(prev_tops))

    # Window set changed (split/close): full redraw
    if current_win_ids != prev_win_ids do
      nil
    else
      prev_versions = Process.get(:emit_prev_buf_versions, %{})

      prev = %{
        tops: prev_tops,
        rects: prev_rects,
        gutter_ws: prev_gutter_ws,
        buf_versions: prev_versions
      }

      deltas =
        Enum.reduce_while(layout.window_layouts, [], fn {win_id, win_layout}, acc ->
          window = Map.get(state.windows.map, win_id)
          check_window_scroll(window, win_id, win_layout, prev, acc)
        end)

      case deltas do
        list when is_list(list) and list != [] -> Enum.reverse(list)
        _ -> nil
      end
    end
  end

  @spec check_window_scroll(
          Minga.Editor.Window.t() | nil,
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
          Minga.Editor.Window.t(),
          pos_integer(),
          Layout.window_layout(),
          map(),
          list()
        ) :: {:cont, list()} | {:halt, atom()}
  defp compare_window_scroll(window, win_id, win_layout, prev, acc) do
    prev_rect = Map.get(prev.rects, win_id)
    current_rect = win_layout.content

    prev_gutter_w = Map.get(prev.gutter_ws, win_id)
    current_gutter_w = window.last_gutter_w

    prev_top = Map.get(prev.tops, win_id)
    current_top = window.last_viewport_top

    prev_version = Map.get(prev.buf_versions, win_id)
    current_version = window.last_buf_version

    classify_scroll_delta(
      %{
        prev_rect: prev_rect,
        cur_rect: current_rect,
        prev_gw: prev_gutter_w,
        cur_gw: current_gutter_w,
        prev_top: prev_top,
        cur_top: current_top,
        prev_ver: prev_version,
        cur_ver: current_version
      },
      win_id,
      acc
    )
  end

  # Multi-clause function replacing the cond block (project coding standards).
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

  # Buffer content changed (edits, highlight updates, decorations) during scroll.
  # Fall back to full redraw so shifted rows show correct content.
  defp classify_scroll_delta(%{prev_ver: pv, cur_ver: cv}, _, _) when pv != cv,
    do: {:halt, :content_changed}

  defp classify_scroll_delta(%{cur_rect: rect, prev_top: pt, cur_top: ct}, win_id, acc) do
    {:cont, [%{win_id: win_id, delta: ct - pt, content_rect: rect} | acc]}
  end

  # ── Command building ─────────────────────────────────────────────────────

  @spec build_commands(Frame.t(), [scroll_delta()] | nil) :: [binary()]
  defp build_commands(frame, nil) do
    # Full redraw path (existing behavior)
    DisplayList.to_commands(frame)
  end

  defp build_commands(frame, scroll_deltas) do
    # Scroll region path: skip clear, send scroll_region + partial content + all chrome
    scroll_cmds = build_scroll_commands(scroll_deltas)
    new_content_draws = collect_new_content_draws(frame, scroll_deltas)
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

  @spec build_scroll_commands([scroll_delta()]) :: [binary()]
  defp build_scroll_commands(scroll_deltas) do
    Enum.map(scroll_deltas, fn %{delta: delta, content_rect: {row, _col, _w, height}} ->
      top_row = row
      bottom_row = row + height - 1
      Protocol.encode_scroll_region(top_row, bottom_row, delta)
    end)
  end

  @spec collect_new_content_draws(Frame.t(), [scroll_delta()]) :: [DisplayList.draw()]
  defp collect_new_content_draws(frame, scroll_deltas) do
    # Build new_rows ranges from scroll deltas. Since WindowFrame.rect is
    # always {0, 0, w, h} (draws use absolute screen coords), we can't key
    # by rect. Instead, build a list of new_rows ranges from the content_rects
    # and match layer row keys against them.
    all_new_rows = Enum.map(scroll_deltas, &compute_new_rows/1)

    Enum.flat_map(frame.windows, fn wf ->
      filter_window_draws_for_new_rows(wf, all_new_rows)
    end)
  end

  @spec compute_new_rows(scroll_delta()) :: Range.t()
  defp compute_new_rows(%{delta: delta, content_rect: {row, _col, _w, height}}) do
    if delta > 0 do
      # Scrolled down: new content at the bottom
      bottom = row + height - 1
      (bottom - delta + 1)..bottom
    else
      # Scrolled up: new content at the top
      row..(row + abs(delta) - 1)
    end
  end

  @spec filter_window_draws_for_new_rows(WindowFrame.t(), [Range.t()]) :: [DisplayList.draw()]
  defp filter_window_draws_for_new_rows(wf, all_new_rows) do
    # Draws in layers already use absolute screen coordinates (wf.rect is {0,0,...}).
    # Filter layer entries whose row falls into any of the new_rows ranges.
    gutter = filter_layer_by_ranges(wf.gutter, all_new_rows)
    lines = filter_layer_by_ranges(wf.lines, all_new_rows)
    tildes = filter_layer_by_ranges(wf.tilde_lines, all_new_rows)

    gutter ++ lines ++ tildes
  end

  @spec filter_layer_by_ranges(DisplayList.render_layer(), [Range.t()]) :: [DisplayList.draw()]
  defp filter_layer_by_ranges(layer, ranges) do
    layer
    |> Enum.filter(fn {row, _runs} -> Enum.any?(ranges, fn r -> row in r end) end)
    |> Enum.flat_map(fn {row, runs} ->
      Enum.map(runs, fn {col, text, style} -> {row, col, text, style} end)
    end)
  end

  @spec collect_chrome_draws(Frame.t()) :: [DisplayList.draw()]
  defp collect_chrome_draws(frame) do
    # Modeline draws are inside window frames; extract them all
    modeline_draws =
      Enum.flat_map(frame.windows, fn wf ->
        {row_off, col_off, _w, _h} = wf.rect

        DisplayList.layer_to_draws(wf.modeline)
        |> DisplayList.offset_draws(row_off, col_off)
      end)

    frame.tab_bar ++
      frame.file_tree ++
      frame.agentic_view ++
      frame.separators ++
      frame.agent_panel ++
      frame.minibuffer ++
      modeline_draws ++
      (frame.splash || [])
  end

  @spec collect_overlay_draws(Frame.t()) :: [DisplayList.draw()]
  defp collect_overlay_draws(frame) do
    Enum.flat_map(frame.overlays, fn %Overlay{draws: draws} -> draws end)
  end

  # ── Tracking state ───────────────────────────────────────────────────────

  @spec update_tracking(state()) :: :ok
  defp update_tracking(state) do
    layout = Layout.get(state)

    tops =
      Map.new(layout.window_layouts, fn {win_id, _wl} ->
        window = Map.get(state.windows.map, win_id)

        if window do
          {win_id, window.last_viewport_top}
        else
          {win_id, -1}
        end
      end)

    rects =
      Map.new(layout.window_layouts, fn {win_id, wl} ->
        {win_id, wl.content}
      end)

    gutter_ws =
      Map.new(layout.window_layouts, fn {win_id, _wl} ->
        window = Map.get(state.windows.map, win_id)

        if window do
          {win_id, window.last_gutter_w}
        else
          {win_id, -1}
        end
      end)

    buf_versions =
      Map.new(layout.window_layouts, fn {win_id, _wl} ->
        window = Map.get(state.windows.map, win_id)

        if window do
          {win_id, window.last_buf_version}
        else
          {win_id, -1}
        end
      end)

    Process.put(:emit_prev_viewport_tops, tops)
    Process.put(:emit_prev_content_rects, rects)
    Process.put(:emit_prev_gutter_ws, gutter_ws)
    Process.put(:emit_prev_buf_versions, buf_versions)
    :ok
  end

  # ── Side-channel writes ──────────────────────────────────────────────────

  @spec send_title(state()) :: :ok
  defp send_title(state) do
    format = Options.get(:title_format) |> to_string()
    title = Title.format(state, format)

    # Prepend [!] when any agent tab needs attention
    title =
      if state.tab_bar && TabBar.any_attention?(state.tab_bar) do
        "[!] " <> title
      else
        title
      end

    if title != Process.get(:last_title) do
      Process.put(:last_title, title)
      PortManager.send_commands([Protocol.encode_set_title(title)])
    end

    :ok
  end

  @spec send_window_bg(state()) :: :ok
  defp send_window_bg(state) do
    bg = state.theme.editor.bg

    if bg != Process.get(:last_window_bg) do
      Process.put(:last_window_bg, bg)
      PortManager.send_commands([Protocol.encode_set_window_bg(bg)])
    end

    :ok
  end

  @spec send_gui_tab_bar(state()) :: :ok
  defp send_gui_tab_bar(%{capabilities: caps, tab_bar: %TabBar{} = tb} = state) do
    if Capabilities.gui?(caps) do
      active_buf = active_window_buffer(state)
      cmd = Protocol.encode_gui_tab_bar(tb, active_buf)
      PortManager.send_commands(state.port_manager, [cmd])
    end

    :ok
  end

  defp send_gui_tab_bar(%{tab_bar: nil}), do: :ok

  @spec active_window_buffer(state()) :: pid() | nil
  defp active_window_buffer(%{windows: %{active: win_id, map: map}}) do
    case Map.get(map, win_id) do
      %{buffer: buf} when is_pid(buf) -> buf
      _ -> nil
    end
  end

  @spec send_gui_file_tree(state()) :: :ok
  defp send_gui_file_tree(%{
         capabilities: caps,
         file_tree: %{tree: %Minga.FileTree{} = tree},
         port_manager: pm
       }) do
    if Capabilities.gui?(caps) do
      cmd = Protocol.encode_gui_file_tree(tree)
      PortManager.send_commands(pm, [cmd])
    end

    :ok
  end

  defp send_gui_file_tree(_state), do: :ok

  @spec send_gui_which_key(state()) :: :ok
  defp send_gui_which_key(%{capabilities: caps, whichkey: wk, port_manager: pm}) do
    if Capabilities.gui?(caps) do
      cmd = Protocol.encode_gui_which_key(wk)
      PortManager.send_commands(pm, [cmd])
    end

    :ok
  end

  @spec send_gui_completion(state()) :: :ok
  defp send_gui_completion(%{capabilities: caps, completion: comp, port_manager: pm} = state) do
    if Capabilities.gui?(caps) do
      {cursor_row, cursor_col} = current_cursor_screen_pos(state)
      cmd = Protocol.encode_gui_completion(comp, cursor_row, cursor_col)
      PortManager.send_commands(pm, [cmd])
    end

    :ok
  end

  @spec send_gui_breadcrumb(state()) :: :ok
  defp send_gui_breadcrumb(%{capabilities: caps, port_manager: pm} = state) do
    if Capabilities.gui?(caps) do
      file_path = active_buffer_path(state)

      root =
        case state.file_tree do
          %{tree: %{root: r}} -> r
          _ -> ""
        end

      cmd = Protocol.encode_gui_breadcrumb(file_path, root)
      PortManager.send_commands(pm, [cmd])
    end

    :ok
  end

  @spec send_gui_status_bar(state()) :: :ok
  defp send_gui_status_bar(%{capabilities: caps, port_manager: pm} = state) do
    if Capabilities.gui?(caps) do
      data = build_status_bar_data(state)
      cmd = Protocol.encode_gui_status_bar(data)
      PortManager.send_commands(pm, [cmd])
    end

    :ok
  end

  @spec current_cursor_screen_pos(state()) :: {non_neg_integer(), non_neg_integer()}
  defp current_cursor_screen_pos(state) do
    layout = Layout.get(state)

    case Layout.active_window_layout(layout, state) do
      %{content: {row, col, _w, _h}} ->
        buf = state.buffers.active

        if buf do
          {line, column} = BufferServer.cursor(buf)
          vp = state.viewport
          {row + line - vp.top, col + column}
        else
          {row, col}
        end

      nil ->
        {0, 0}
    end
  end

  @spec active_buffer_path(state()) :: String.t() | nil
  defp active_buffer_path(state) do
    case state.buffers.active do
      nil -> nil
      buf -> BufferServer.file_path(buf)
    end
  end

  @spec build_status_bar_data(state()) :: map()
  defp build_status_bar_data(state) do
    buf = state.buffers.active
    {line, col} = if buf, do: BufferServer.cursor(buf), else: {1, 0}
    line_count = if buf, do: BufferServer.line_count(buf), else: 1
    file_name = if buf, do: BufferServer.file_path(buf) || "", else: ""

    %{
      mode: state.vim.mode,
      cursor_line: line + 1,
      cursor_col: col + 1,
      line_count: line_count,
      filetype: Filetype.detect(file_name),
      dirty_marker: if(buf && BufferServer.dirty?(buf), do: "●", else: ""),
      lsp_status: state.lsp_status,
      git_branch:
        get_in(state, [Access.key(:file_tree), Access.key(:tree)]) &&
          case state.file_tree.tree do
            %{root: _} -> Git.current_branch(state.file_tree.tree.root)
            _ -> nil
          end,
      status_msg: state.status_msg
    }
  end

  @spec send_gui_theme(state()) :: :ok
  defp send_gui_theme(state) do
    if Capabilities.gui?(state.capabilities) do
      theme_name = state.theme.name

      if theme_name != Process.get(:last_gui_theme) do
        Process.put(:last_gui_theme, theme_name)
        PortManager.send_commands(state.port_manager, [Protocol.encode_gui_theme(state.theme)])
      end
    end

    :ok
  end
end
