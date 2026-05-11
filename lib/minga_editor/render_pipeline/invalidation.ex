defmodule MingaEditor.RenderPipeline.Invalidation do
  @moduledoc """
  Output of Stage 1 (Invalidation) — first-class dirty information that
  downstream stages consult to skip work for clean windows and chrome
  regions.

  ## Fields

  - `full_redraw` — when true, downstream stages ignore the per-window
    and per-region detail and rebuild everything. This is the today
    behavior and the safe default while Phase 1 dirty tracking is
    being wired in.
  - `windows` — per-window dirty info (`Window.id() => WindowDirty.t()`).
    A window's mode is one of `:clean` (no work needed), `:rows`
    (only the listed `dirty_rows` need redrawing), or `:all` (the
    whole window must rebuild).
  - `chrome_regions` — set of dirty chrome region tags
    (`:tab_bar`, `:status_bar`, `:file_tree`, `:agent_panel`,
    `:minibuffer`, `:modeline`). When a region isn't in the set,
    the chrome stage reuses its cached drawing.
  - `global_reasons` — root causes that triggered global
    invalidation (`:theme_changed`, `:font_changed`, `:resize`,
    `:focus_change`, etc.). Carried for telemetry; no behavioral
    effect today.

  ## Phase 1 status

  This struct is the contract Stage 1 will produce when the dirty
  tracking arrives. Today the producer always returns a struct with
  `full_redraw: true` and empty maps, so behavior is unchanged.
  Stage 2 (#1431 Phase 2) implements the per-row dirty algebra and
  Stage 3 lifts it into the pipeline consumers.
  """

  alias Minga.Buffer
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.WindowDirty
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Viewport

  @typedoc "Chrome region tags."
  @type region_tag ::
          :tab_bar
          | :status_bar
          | :file_tree
          | :agent_panel
          | :minibuffer
          | :modeline

  @typedoc "Dirty chrome regions tracked as a MapSet of region tags."
  @type chrome_regions :: %MapSet{map: %{optional(region_tag()) => []}} | nil

  @typedoc "Output of Stage 1."
  @type t :: %__MODULE__{
          full_redraw: boolean(),
          windows: %{integer() => WindowDirty.t()},
          chrome_regions: chrome_regions(),
          global_reasons: [atom()]
        }

  defstruct full_redraw: true,
            windows: %{},
            chrome_regions: nil,
            global_reasons: []

  @doc """
  Returns a fresh Invalidation requesting a full redraw — the safe
  default while incremental tracking is staged in.
  """
  @spec full_redraw([atom()]) :: t()
  def full_redraw(reasons \\ []) do
    %__MODULE__{
      full_redraw: true,
      windows: %{},
      chrome_regions: MapSet.new(),
      global_reasons: reasons
    }
  end

  @doc "Builds per-window dirty data from the current render caches and cheap buffer metadata."
  @spec from_input(Input.t(), Layout.t()) :: t()
  def from_input(%Input{} = input, %Layout{} = layout) do
    windows = dirty_windows(input, layout)

    %__MODULE__{
      full_redraw: false,
      windows: windows,
      chrome_regions: chrome_regions(input),
      global_reasons: []
    }
  end

  @doc "Returns the dirty entry for a window, defaulting to full redraw when detail is unavailable."
  @spec window_dirty(t() | nil, integer()) :: WindowDirty.t()
  def window_dirty(nil, _win_id), do: WindowDirty.all(:missing_invalidation)
  def window_dirty(%__MODULE__{full_redraw: true}, _win_id), do: WindowDirty.all(:full_redraw)

  def window_dirty(%__MODULE__{windows: windows}, win_id) do
    Map.get(windows, win_id, WindowDirty.all(:missing_window))
  end

  @doc "Returns true when any chrome region is dirty."
  @spec chrome_dirty?(t() | nil) :: boolean()
  def chrome_dirty?(nil), do: true
  def chrome_dirty?(%__MODULE__{full_redraw: true}), do: true
  def chrome_dirty?(%__MODULE__{chrome_regions: nil}), do: true
  def chrome_dirty?(%__MODULE__{chrome_regions: regions}), do: MapSet.size(regions) > 0

  # ── Private ──────────────────────────────────────────────────────────────

  @spec dirty_windows(Input.t(), Layout.t()) :: %{integer() => WindowDirty.t()}
  defp dirty_windows(input, layout) do
    Map.new(layout.window_layouts, fn {win_id, _win_layout} ->
      window = Map.get(input.workspace.windows.map, win_id)
      {win_id, dirty_for_window(input, window)}
    end)
  end

  @spec dirty_for_window(Input.t(), MingaEditor.Window.t() | nil) :: WindowDirty.t()
  defp dirty_for_window(_input, nil), do: WindowDirty.all(:missing_window)

  defp dirty_for_window(_input, %{content: {:agent_chat, _}}), do: WindowDirty.all(:agent_chat)

  defp dirty_for_window(input, window) do
    cache = window.render_cache

    case cache.dirty_lines do
      :all ->
        WindowDirty.all(:cached_dirty)

      dirty when map_size(dirty) > 0 ->
        WindowDirty.rows(Map.keys(dirty), :cached_rows)

      _ ->
        dirty_from_context(input, window)
    end
  end

  @spec dirty_from_context(Input.t(), MingaEditor.Window.t()) :: WindowDirty.t()
  defp dirty_from_context(input, window) do
    if context_requires_rebuild?(input, window) do
      WindowDirty.all(:context_changed)
    else
      dirty_from_metadata(input, window)
    end
  end

  @spec context_requires_rebuild?(Input.t(), MingaEditor.Window.t()) :: boolean()
  defp context_requires_rebuild?(input, window) do
    visual_context_changed?(input, window) or decorations_changed?(window)
  end

  @spec visual_context_changed?(Input.t(), MingaEditor.Window.t()) :: boolean()
  defp visual_context_changed?(input, window) do
    cached_visual = cached_visual_selection(window.render_cache.last_context_fingerprint)
    input.workspace.editing.mode == :visual or cached_visual != nil
  end

  @spec cached_visual_selection(term()) :: term()
  defp cached_visual_selection({visual_selection, _, _, _, _, _, _, _, _, _, _}),
    do: visual_selection

  defp cached_visual_selection(_fingerprint), do: nil

  @spec decorations_changed?(MingaEditor.Window.t()) :: boolean()
  defp decorations_changed?(window) do
    cached_version = cached_decorations_version(window.render_cache.last_context_fingerprint)

    cached_version != nil and
      safe_decorations_version(window.buffer, cached_version) != cached_version
  end

  @spec cached_decorations_version(term()) :: non_neg_integer() | nil
  defp cached_decorations_version({_, _, _, _, _, _, _, _, _, _, decorations_version}) do
    decorations_version
  end

  defp cached_decorations_version(_fingerprint), do: nil

  @spec safe_decorations_version(pid(), non_neg_integer()) :: non_neg_integer()
  defp safe_decorations_version(buffer, fallback) do
    Buffer.decorations_version(buffer)
  catch
    :exit, _ -> fallback
  end

  @spec dirty_from_metadata(Input.t(), MingaEditor.Window.t()) :: WindowDirty.t()
  defp dirty_from_metadata(input, window) do
    cache = window.render_cache

    if cache.last_window_frame == nil or cache.last_buf_version < 0 do
      WindowDirty.all(:first_frame)
    else
      compare_metadata(input, window)
    end
  end

  @spec compare_metadata(Input.t(), MingaEditor.Window.t()) :: WindowDirty.t()
  defp compare_metadata(input, window) do
    cache = window.render_cache
    {cursor_line, cursor_col} = current_cursor(input, window)
    line_count = safe_line_count(window.buffer, cache.last_line_count)
    version = safe_version(window.buffer, cache.last_buf_version)
    gutter_w = current_gutter_width(window.buffer, line_count, cache.last_gutter_w)

    classify_metadata_change(
      cache,
      line_count,
      version,
      gutter_w,
      cursor_line,
      cursor_col,
      window.buffer
    )
  catch
    :exit, _ -> WindowDirty.all(:buffer_unavailable)
  end

  @spec classify_metadata_change(
          MingaEditor.Window.RenderCache.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pid()
        ) :: WindowDirty.t()
  defp classify_metadata_change(
         cache,
         line_count,
         version,
         gutter_w,
         cursor_line,
         cursor_col,
         buffer
       ) do
    first_frame = cache.last_line_count < 0 or cache.last_gutter_w < 0

    if first_frame or line_count != cache.last_line_count or gutter_w != cache.last_gutter_w do
      WindowDirty.all(:structural_change)
    else
      classify_version_change(cache, version, cursor_line, cursor_col, buffer)
    end
  end

  @spec classify_version_change(
          MingaEditor.Window.RenderCache.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pid()
        ) :: WindowDirty.t()
  defp classify_version_change(cache, version, cursor_line, cursor_col, buffer) do
    if version != cache.last_buf_version do
      WindowDirty.all(:buffer_version_changed)
    else
      classify_cursor_change(cache, cursor_line, cursor_col, buffer)
    end
  end

  @spec classify_cursor_change(
          MingaEditor.Window.RenderCache.t(),
          non_neg_integer(),
          non_neg_integer(),
          pid()
        ) :: WindowDirty.t()
  defp classify_cursor_change(cache, cursor_line, cursor_col, buffer) do
    if cursor_line == cache.last_cursor_line and cursor_col == cache.last_cursor_col do
      WindowDirty.clean()
    else
      line_number_style = safe_option(buffer, :line_numbers, :absolute)
      dirty_cursor_rows(cache.last_cursor_line, cursor_line, line_number_style)
    end
  end

  @spec dirty_cursor_rows(integer(), non_neg_integer(), atom()) :: WindowDirty.t()
  defp dirty_cursor_rows(_old_cursor, _cursor_line, style) when style in [:relative, :hybrid] do
    WindowDirty.all(:cursor_moved)
  end

  defp dirty_cursor_rows(old_cursor, _cursor_line, _style) when old_cursor < 0 do
    WindowDirty.all(:cursor_moved)
  end

  defp dirty_cursor_rows(old_cursor, cursor_line, _style) do
    WindowDirty.rows([old_cursor, cursor_line], :cursor_moved)
  end

  @spec current_cursor(Input.t(), MingaEditor.Window.t()) ::
          {non_neg_integer(), non_neg_integer()}
  defp current_cursor(input, window) do
    if window.id == input.workspace.windows.active do
      Buffer.cursor(window.buffer)
    else
      window.cursor
    end
  end

  @spec current_gutter_width(pid(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp current_gutter_width(buffer, line_count, fallback) do
    line_number_style = safe_option(buffer, :line_numbers, :absolute)

    if line_number_style == :none do
      Gutter.total_width(0)
    else
      line_count |> Viewport.gutter_width() |> Gutter.total_width()
    end
  catch
    :exit, _ -> fallback
  end

  @spec safe_line_count(pid(), non_neg_integer()) :: non_neg_integer()
  defp safe_line_count(buffer, fallback) do
    Buffer.line_count(buffer)
  catch
    :exit, _ -> fallback
  end

  @spec safe_version(pid(), non_neg_integer()) :: non_neg_integer()
  defp safe_version(buffer, fallback) do
    Buffer.version(buffer)
  catch
    :exit, _ -> fallback
  end

  @spec safe_option(pid(), atom(), term()) :: term()
  defp safe_option(buffer, option, fallback) do
    Buffer.get_option(buffer, option)
  catch
    :exit, _ -> fallback
  end

  @spec chrome_regions(Input.t()) :: chrome_regions()
  defp chrome_regions(input) do
    fingerprint = Input.chrome_fingerprint(input)

    if fingerprint == input.caches.chrome_prev_fingerprint and
         input.caches.chrome_prev_result != nil do
      MapSet.new()
    else
      all_chrome_regions()
    end
  end

  @spec all_chrome_regions() :: chrome_regions()
  defp all_chrome_regions do
    MapSet.new([:tab_bar, :status_bar, :file_tree, :agent_panel, :minibuffer, :modeline])
  end

  @doc """
  Sanity-mode env flag. When `MINGA_RENDER_SANITY=1`, a follow-up
  Phase 1 implementation will run the pipeline twice (incremental +
  full) and assert byte-equal output, emitting a
  `[:minga, :render, :sanity_violation]` telemetry event on
  divergence. The flag exists today so the env-var contract is
  documented; the comparison itself is wired in the Phase 1 follow-up.
  """
  @spec sanity_mode?() :: boolean()
  def sanity_mode? do
    System.get_env("MINGA_RENDER_SANITY") == "1"
  end
end
