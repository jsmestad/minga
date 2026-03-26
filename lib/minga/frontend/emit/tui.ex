defmodule Minga.Frontend.Emit.TUI do
  @moduledoc """
  TUI-specific command building for the Emit stage.

  Converts a composed `Frame` into protocol command binaries for the
  Zig/libvaxis TUI renderer. Handles scroll region optimization when
  the viewport shifts by a small delta between frames.

  ## Scroll region optimization

  When the viewport shifts by 1-3 lines between frames and no structural
  changes occurred (layout, gutter width, window set), we send a
  `scroll_region` command instead of a full `clear + redraw`. The terminal
  emulator shifts its internal buffer, then only the newly revealed lines
  are drawn. This eliminates the majority of cell writes for the most
  common scroll case (Ctrl-e/y, mouse wheel, cursor near edges).

  Currently disabled pending a libvaxis buffer sync fix.
  """

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Frame, Overlay, WindowFrame}
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Frontend.Protocol

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
  Builds protocol command binaries from a frame for the TUI renderer.

  Detects scroll regions from tracking state and uses scroll region
  optimization when possible, otherwise does a full redraw.
  """
  @spec build_commands(Frame.t(), state()) :: [binary()]
  def build_commands(frame, state) do
    scroll_deltas = detect_scroll_regions(state)
    build_commands_from_deltas(frame, scroll_deltas)
  end

  @doc """
  Builds protocol commands from a frame and pre-computed scroll deltas.

  When `scroll_deltas` is nil, performs a full redraw via `DisplayList.to_commands/1`.
  When scroll deltas are present, sends scroll_region commands + partial content + chrome.
  """
  @spec build_commands_from_deltas(Frame.t(), [scroll_delta()] | nil) :: [binary()]
  def build_commands_from_deltas(frame, nil) do
    DisplayList.to_commands(frame)
  end

  def build_commands_from_deltas(frame, scroll_deltas) do
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

  # ── Scroll region detection ──────────────────────────────────────────────

  @spec detect_scroll_regions(state()) :: [scroll_delta()] | nil
  defp detect_scroll_regions(state) do
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
          window = Map.get(state.workspace.windows.map, win_id)
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

  defp classify_scroll_delta(%{cur_rect: rect, prev_top: pt, cur_top: ct}, win_id, acc) do
    {:cont, [%{win_id: win_id, delta: ct - pt, content_rect: rect} | acc]}
  end

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
    all_new_rows = Enum.map(scroll_deltas, &compute_new_rows/1)

    Enum.flat_map(frame.windows, fn wf ->
      filter_window_draws_for_new_rows(wf, all_new_rows)
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
