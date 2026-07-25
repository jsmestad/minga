defmodule MingaEditor.RenderPipeline.ContentHelpers do
  @moduledoc """
  Semantic-input helpers for the Content stage of the render pipeline.

  Builds the per-frame `Renderer.Context` that the window model builder
  consumes, computes visual selection bounds, merges search and
  document-highlight decorations, and resolves window-local highlight and
  sign data. These are the inputs the semantic window model is built from.

  The cell-grid line producers for the retired Zig frontend were removed in
  #2241; only these semantic-input helpers remain.
  """

  alias Minga.Buffer
  alias Minga.Config
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Core.Unicode
  alias Minga.Diagnostics
  alias MingaEditor.InlineAsk.Render, as: InlineAskRender
  alias MingaEditor.InlineEdit.Render, as: InlineEditRender
  alias MingaEditor.State.Mouse
  alias MingaEditor.Renderer.Context
  alias MingaEditor.Renderer.SearchHighlight
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Shell.Traditional.NavFlash
  alias Minga.Git
  alias Minga.LSP.SyncServer
  alias Minga.Mode.VisualState
  alias MingaEditor.UI.Highlight

  @type state :: Input.t()
  @type window :: MingaEditor.Renderer.RenderWindow.t() | MingaEditor.Window.t()

  @type visual_selection :: Context.visual_selection()

  # ── Render context ─────────────────────────────────────────────────────────

  @doc """
  Builds the per-frame render context for a window.

  Returns the context and an updated state with inter-frame caches
  (search decorations, document-highlight decorations) written back.
  """
  @spec build_render_ctx(state(), window(), map()) :: {Context.t(), state()}
  def build_render_ctx(state, window, params) do
    %{
      viewport: viewport,
      cursor: cursor,
      lines: lines,
      first_line: first_line,
      preview_matches: preview_matches,
      gutter_w: gutter_w,
      content_w: content_w,
      has_sign_column: has_sign_column,
      is_active: is_active
    } = params

    decorations = window_decorations(state, window, Map.get(params, :decorations))

    visual_selection =
      if is_active do
        sel = visual_selection_grapheme_bounds(state, cursor, lines, first_line)
        adjust_selection_for_virtual_text(sel, decorations)
      else
        nil
      end

    search_matches =
      case preview_matches do
        [] -> SearchHighlight.search_matches_for_lines(state, lines, first_line)
        _ -> preview_matches
      end

    confirm_match = if(is_active, do: SearchHighlight.current_confirm_match(state), else: nil)

    # Merge search matches into decorations as highlight ranges so they
    # compose with tree-sitter syntax colors (bg overlay preserving fg).
    # Only rebuild when the match set actually changed (avoid per-frame
    # clear-and-reapply when nothing changed).
    {decorations, search_cache} =
      merge_search_decorations(
        decorations,
        search_matches,
        confirm_match,
        state.theme.search,
        state.caches.search_decoration_cache
      )

    {decorations, doc_highlight_cache} =
      if is_active do
        merge_document_highlight_decorations(
          decorations,
          state.workspace.document_highlights,
          state.theme,
          state.caches.doc_highlight_cache
        )
      else
        {decorations, state.caches.doc_highlight_cache}
      end

    {decorations, cmd_hover_link_cache} =
      if is_active do
        merge_cmd_hover_link_decoration(
          decorations,
          state.workspace.cmd_hover_link,
          state.theme,
          state.caches.cmd_hover_link_cache
        )
      else
        {decorations, state.caches.cmd_hover_link_cache}
      end

    state = %{
      state
      | caches: %{
          state.caches
          | search_decoration_cache: search_cache,
            doc_highlight_cache: doc_highlight_cache,
            cmd_hover_link_cache: cmd_hover_link_cache
        }
    }

    cursorline_bg =
      if is_active and Config.get(:cursorline) do
        state.theme.editor.cursorline_bg
      else
        nil
      end

    {show_invisible, tab_width, whitespace_face} =
      invisible_char_settings(Map.get(params, :options, %{}), state.theme)

    ctx = %Context{
      viewport: viewport,
      visual_selection: visual_selection,
      search_matches: search_matches,
      gutter_w: gutter_w,
      content_w: content_w,
      confirm_match: confirm_match,
      highlight: window_highlight(state, window),
      cursorline_bg: cursorline_bg,
      nav_flash: active_nav_flash(state.shell_state.flashes.nav),
      nav_flash_bg: state.theme.editor.nav_flash_bg,
      editor_bg: state.theme.editor.bg,
      has_sign_column: has_sign_column,
      decorations: decorations,
      diagnostic_signs: diagnostic_signs_for_path(Map.get(params, :file_path)),
      git_signs: prefetched_git_signs(params, state, window),
      gutter_colors: state.theme.gutter,
      git_colors: state.theme.git,
      show_invisible: show_invisible,
      tab_width: tab_width,
      whitespace_face: whitespace_face,
      search_colors: state.theme.search,
      document_highlight_colors: document_highlight_colors(state.theme),
      wrap_on: Map.get(params, :wrap_on, false),
      line_number_style: Map.get(params, :line_number_style, :absolute),
      width_oracle: Map.get(params, :width_oracle, %Minga.Core.WidthOracle.Monospace{}),
      indent_guide_face:
        Face.new(fg: state.theme.editor.indent_guide_fg || state.theme.gutter.fg),
      indent_guide_active_face:
        Face.new(fg: state.theme.editor.indent_guide_active_fg || state.theme.gutter.current_fg),
      hl_todo_faces: MingaEditor.UI.Theme.hl_todo_faces(state.theme),
      cursor_col: Map.get(params, :cursor_col, cursor_display_col(lines, cursor, first_line)),
      cursor_line: elem(cursor, 0),
      hover_row: extract_hover_row(state),
      fold_ranges: window.fold_ranges
    }

    {ctx, state}
  end

  @spec extract_hover_row(state()) :: non_neg_integer() | nil
  defp extract_hover_row(state) do
    case Mouse.hover_position(state.workspace.mouse) do
      {row, _col} when is_integer(row) -> row
      _ -> nil
    end
  end

  # ── Window data ────────────────────────────────────────────────────────────

  # Adjusts visual selection display columns to account for inline virtual
  # text that displaces buffer content rightward.
  @spec adjust_selection_for_virtual_text(visual_selection(), Decorations.t()) ::
          visual_selection()
  defp adjust_selection_for_virtual_text(nil, _decs), do: nil
  defp adjust_selection_for_virtual_text({:line, _, _} = sel, _decs), do: sel

  defp adjust_selection_for_virtual_text({:char, {sl, sc}, {el, ec}}, decs) do
    {:char, {sl, Decorations.buf_col_to_display_col(decs, sl, sc)},
     {el, Decorations.buf_col_to_display_col(decs, el, ec)}}
  end

  # Converts search matches into highlight range decorations and merges
  # them into the decorations struct. Search highlights use a lower priority
  # than user decorations so they don't override intentional styling.
  # The current confirm match gets a different bg and higher priority.
  # Only rebuilds search decorations when the match set changes.
  # Uses a fingerprint of the matches to detect changes.
  @typedoc "Search decoration cache: {search_fingerprint, base_version, merged_decorations}"
  @type search_cache ::
          {term(), non_neg_integer(), Decorations.t()} | nil

  @doc """
  Merges search match highlights into a decorations struct, with caching.

  Returns `{merged_decorations, updated_cache}`. The cache is keyed on both
  the search fingerprint (matches + confirm) AND the base decoration version.
  When the base version changes (e.g., agent chat decorations updated between
  frames), the cache misses and search highlights are rebuilt on the fresh base.
  """
  @spec merge_search_decorations(
          Decorations.t(),
          [Minga.Editing.Search.Match.t()],
          Minga.Editing.Search.Match.t() | nil,
          map(),
          search_cache()
        ) :: {Decorations.t(), search_cache()}
  def merge_search_decorations(decs, matches, confirm_match, colors, cached) do
    fingerprint = {matches, confirm_match, colors}

    case cached do
      {^fingerprint, base_version, cached_decs} when base_version == decs.version ->
        {cached_decs, cached}

      _ ->
        result = rebuild_search_decorations(decs, matches, confirm_match, colors)
        new_cache = {fingerprint, decs.version, result}
        {result, new_cache}
    end
  end

  defp rebuild_search_decorations(decs, [], _confirm, _colors) do
    Decorations.remove_group(decs, :search)
  end

  defp rebuild_search_decorations(decs, matches, confirm_match, colors) do
    Decorations.batch(decs, fn d ->
      d = Decorations.remove_group(d, :search)

      Enum.reduce(matches, d, fn match, acc ->
        add_search_highlight(acc, match, confirm_match, colors)
      end)
    end)
  end

  defp add_search_highlight(
         decs,
         %Minga.Editing.Search.Match{line: line, col: col, length: len} = match,
         confirm_match,
         colors
       ) do
    is_confirm = confirm_match != nil and match == confirm_match

    {style, priority} =
      if is_confirm do
        {Face.new(bg: colors.current_bg, fg: colors.highlight_fg), -5}
      else
        {Face.new(bg: colors.highlight_bg, fg: colors.highlight_fg), -10}
      end

    {_id, decs} =
      Decorations.add_highlight(decs, {line, col}, {line, col + len},
        style: style,
        priority: priority,
        group: :search
      )

    decs
  end

  # ── Document highlight decorations ──────────────────────────────────────────

  # Merges LSP document highlights into decorations with caching.
  # Returns {merged_decorations, updated_cache}.
  @spec merge_document_highlight_decorations(
          Decorations.t(),
          [Minga.LSP.DocumentHighlight.t()] | nil,
          MingaEditor.UI.Theme.t(),
          term()
        ) :: {Decorations.t(), term()}
  defp merge_document_highlight_decorations(decs, nil, _theme, cache), do: {decs, cache}
  defp merge_document_highlight_decorations(decs, [], _theme, cache), do: {decs, cache}

  defp merge_document_highlight_decorations(decs, highlights, theme, cached) do
    fingerprint = {highlights, decs.version, document_highlight_colors(theme)}

    case cached do
      {^fingerprint, cached_decs} ->
        {cached_decs, cached}

      _ ->
        result = rebuild_document_highlight_decorations(decs, highlights, theme)
        new_cache = {fingerprint, result}
        {result, new_cache}
    end
  end

  @spec rebuild_document_highlight_decorations(
          Decorations.t(),
          [Minga.LSP.DocumentHighlight.t()],
          MingaEditor.UI.Theme.t()
        ) :: Decorations.t()
  defp rebuild_document_highlight_decorations(decs, highlights, theme) do
    Decorations.batch(decs, fn d ->
      d = Decorations.remove_group(d, :document_highlight)

      Enum.reduce(highlights, d, fn hl, acc ->
        bg = document_highlight_bg(hl.kind, theme)
        style = Face.new(bg: bg)

        {_id, acc} =
          Decorations.add_highlight(acc, {hl.start_line, hl.start_col}, {hl.end_line, hl.end_col},
            style: style,
            priority: -15,
            group: :document_highlight
          )

        acc
      end)
    end)
  end

  # Resolve background color for document highlights from the theme.
  # Uses subtle, muted colors that are visible but don't compete with
  # search highlights (priority -10) or selection.
  @spec document_highlight_bg(Minga.LSP.DocumentHighlight.kind(), MingaEditor.UI.Theme.t()) ::
          MingaEditor.UI.Theme.color()
  defp document_highlight_bg(:write, theme), do: elem(document_highlight_colors(theme), 1)
  defp document_highlight_bg(_kind, theme), do: elem(document_highlight_colors(theme), 0)

  @spec document_highlight_colors(MingaEditor.UI.Theme.t()) ::
          {non_neg_integer(), non_neg_integer()}
  defp document_highlight_colors(theme) do
    {
      theme.editor.highlight_read_bg || 0x3A3F4B,
      theme.editor.highlight_write_bg || 0x4A3F2B
    }
  end

  # ── Cmd/Ctrl-hover link decoration (#2630) ──────────────────────────────────

  @doc """
  Merges the transient Cmd/Ctrl-hover go-to-definition link into decorations.

  Styles the full word range with an underline in the theme link/accent color so
  it reads as a clickable link rather than its original syntax color (#2630).
  Returns `{merged_decorations, updated_cache}`. Cached on the link range + base
  decoration version + color so an unchanged preview never rebuilds decorations
  (and so never forces an idle re-render).
  """
  @spec merge_cmd_hover_link_decoration(
          Decorations.t(),
          {Buffer.position(), Buffer.position()} | nil,
          MingaEditor.UI.Theme.t(),
          term()
        ) :: {Decorations.t(), term()}
  def merge_cmd_hover_link_decoration(decs, nil, _theme, nil), do: {decs, nil}

  def merge_cmd_hover_link_decoration(decs, nil, _theme, _cache) do
    {Decorations.remove_group(decs, :cmd_hover_link), nil}
  end

  def merge_cmd_hover_link_decoration(decs, {start_pos, end_pos} = link, theme, cached) do
    fingerprint = {link, decs.version, cmd_hover_link_color(theme)}

    case cached do
      {^fingerprint, cached_decs} ->
        {cached_decs, cached}

      _ ->
        result = rebuild_cmd_hover_link_decoration(decs, start_pos, end_pos, theme)
        {result, {fingerprint, result}}
    end
  end

  @spec rebuild_cmd_hover_link_decoration(
          Decorations.t(),
          Buffer.position(),
          Buffer.position(),
          MingaEditor.UI.Theme.t()
        ) :: Decorations.t()
  defp rebuild_cmd_hover_link_decoration(decs, start_pos, end_pos, theme) do
    Decorations.batch(decs, fn d ->
      d = Decorations.remove_group(d, :cmd_hover_link)
      style = Face.new(fg: cmd_hover_link_color(theme), underline: true)

      {_id, d} =
        Decorations.add_highlight(d, start_pos, end_pos,
          style: style,
          priority: -8,
          group: :cmd_hover_link
        )

      d
    end)
  end

  # The theme's link/accent color, falling back to a blue accent when a theme
  # does not define one.
  @spec cmd_hover_link_color(MingaEditor.UI.Theme.t()) :: non_neg_integer()
  defp cmd_hover_link_color(theme) do
    theme.editor.link_fg || 0x61AFEF
  end

  @doc "Returns the decorations for a window's buffer."
  @spec window_decorations(term(), window(), Decorations.t() | nil) :: Decorations.t()
  def window_decorations(state, %{content: {:buffer, buf}}, %Decorations{} = decorations)
      when is_pid(buf) do
    decorations
    |> InlineAskRender.merge_decorations(state, buf)
    |> InlineEditRender.merge_decorations(state, buf)
    |> maybe_build_vt_line_cache()
  end

  def window_decorations(_state, _window, _decorations), do: Decorations.new()

  @spec maybe_build_vt_line_cache(Decorations.t()) :: Decorations.t()
  defp maybe_build_vt_line_cache(%Decorations{virtual_texts: []} = decorations), do: decorations

  defp maybe_build_vt_line_cache(%Decorations{} = decorations),
    do: Decorations.build_vt_line_cache(decorations)

  @doc "Returns the highlight state for a window's buffer."
  @spec window_highlight(state(), window()) :: MingaEditor.UI.Highlight.t() | nil
  def window_highlight(state, %{content: {:buffer, buffer}}) do
    hl =
      case Map.fetch(state.highlighting.highlights, buffer) do
        {:ok, highlight} -> highlight
        :error -> MingaEditor.UI.Highlight.from_theme(state.theme)
      end

    semantic_layer = Map.get(state.semantic_tokens, buffer)

    if hl.capture_names == {} and semantic_layer == nil do
      nil
    else
      hl
      |> apply_buffer_face_overrides(buffer, state)
      |> maybe_compose_semantic_layer(semantic_layer)
    end
  end

  @spec maybe_compose_semantic_layer(Highlight.t(), MingaEditor.State.LSP.semantic_layer() | nil) ::
          Highlight.t()
  defp maybe_compose_semantic_layer(hl, nil), do: hl
  defp maybe_compose_semantic_layer(hl, layer), do: Highlight.compose_semantic_layer(hl, layer)

  # Applies buffer-local face overrides to the highlight's face registry.
  # Reads from the editor's pre-computed face_override_registries map,
  # which is updated via push from Buffer.Process when overrides change.
  # Zero GenServer calls on the render path.
  @spec apply_buffer_face_overrides(Highlight.t(), pid(), state()) :: Highlight.t()
  defp apply_buffer_face_overrides(hl, buf_pid, state) when is_pid(buf_pid) do
    case Map.get(state.face_override_registries, buf_pid) do
      nil -> hl
      registry -> %{hl | face_registry: registry}
    end
  end

  @doc "Returns diff-view signs when a diff view is active, otherwise git signs for a window's buffer."
  @spec signs_for_window(state(), window()) :: %{non_neg_integer() => atom()}
  def signs_for_window(%{diff_views: diff_views}, %{content: {:buffer, buf}} = window)
      when is_pid(buf) and is_map(diff_views) do
    case Map.get(diff_views, buf) do
      nil -> git_signs_for_window(window)
      info -> diff_signs_from_metadata(info.line_metadata)
    end
  end

  def signs_for_window(_state, window), do: git_signs_for_window(window)

  @spec diff_signs_from_metadata([Minga.Core.DiffView.line_meta()]) ::
          %{non_neg_integer() => atom()}
  defp diff_signs_from_metadata(line_metadata) do
    line_metadata
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {%{type: :added}, idx}, acc -> Map.put(acc, idx, :added)
      {%{type: :removed}, idx}, acc -> Map.put(acc, idx, :removed)
      _, acc -> acc
    end)
  end

  @spec prefetched_git_signs(map(), state(), window()) :: %{non_neg_integer() => atom()}
  defp prefetched_git_signs(%{git_signs: signs}, _state, _window) when is_map(signs), do: signs
  defp prefetched_git_signs(_params, state, window), do: signs_for_window(state, window)

  @doc "Returns git signs for a window's buffer."
  @spec git_signs_for_window(window()) :: %{non_neg_integer() => atom()}
  def git_signs_for_window(%{content: {:buffer, buf}}) when is_pid(buf) do
    case Git.tracking_pid(buf) do
      nil ->
        %{}

      git_pid ->
        try do
          Git.gutter_signs(git_pid)
        catch
          :exit, _ -> %{}
        end
    end
  end

  @doc "Returns diagnostic signs for a window's buffer."
  @spec diagnostic_signs_for_window(window()) :: %{non_neg_integer() => atom()}
  def diagnostic_signs_for_window(%{content: {:buffer, buf}}) when is_pid(buf) do
    case Buffer.file_path(buf) do
      nil -> %{}
      path -> diagnostic_signs_for_path(path)
    end
  end

  @doc "Returns diagnostic signs for a buffer path."
  @spec diagnostic_signs_for_path(String.t() | nil) :: %{non_neg_integer() => atom()}
  def diagnostic_signs_for_path(nil), do: %{}

  def diagnostic_signs_for_path(path) when is_binary(path) do
    Diagnostics.gutter_signs_by_line(SyncServer.path_to_uri(path))
  end

  # ── Visual selection ───────────────────────────────────────────────────────

  @doc "Computes visual selection bounds in display columns."
  @spec visual_selection_grapheme_bounds(
          state(),
          Buffer.position(),
          [String.t()],
          non_neg_integer()
        ) :: visual_selection()
  def visual_selection_grapheme_bounds(state, cursor, lines, first_line) do
    case visual_selection_bounds(state, cursor) do
      nil ->
        nil

      {:line, _, _} = sel ->
        sel

      {:char, {sl, sc}, {el, ec}} ->
        {
          :char,
          {sl, byte_col_to_display(lines, sl, sc, first_line)},
          {el, byte_col_to_display_end(lines, el, ec, first_line)}
        }
    end
  end

  @doc "Computes raw visual selection bounds (byte columns)."
  @spec visual_selection_bounds(state(), Buffer.position()) :: visual_selection()
  def visual_selection_bounds(
        %{workspace: %{editing: %{mode: :visual, mode_state: %VisualState{} = ms}}},
        cursor
      ) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type

    case visual_type do
      :char ->
        {start_pos, end_pos} = sort_positions(anchor, cursor)
        {:char, start_pos, end_pos}

      :line ->
        {anchor_line, _} = anchor
        {cursor_line, _} = cursor
        {:line, min(anchor_line, cursor_line), max(anchor_line, cursor_line)}
    end
  end

  def visual_selection_bounds(_state, _cursor), do: nil

  @spec active_nav_flash(NavFlash.t()) :: NavFlash.t() | nil
  defp active_nav_flash(%NavFlash{} = flash) do
    if NavFlash.active?(flash), do: flash, else: nil
  end

  # ── Context fingerprint ─────────────────────────────────────────────────────

  @doc "Computes a fingerprint from the render context for change detection."
  @spec context_fingerprint(Context.t(), boolean()) ::
          MingaEditor.Renderer.WindowCache.context_fingerprint()
  def context_fingerprint(%Context{} = ctx, is_active) do
    {
      ctx.visual_selection,
      ctx.search_matches,
      highlight_fingerprint(ctx.highlight),
      ctx.diagnostic_signs,
      ctx.git_signs,
      ctx.viewport.left,
      ctx.viewport.cols,
      ctx.content_w,
      is_active,
      ctx.confirm_match,
      ctx.decorations.version,
      ctx.show_invisible,
      ctx.tab_width,
      ctx.cursorline_bg,
      ctx.nav_flash,
      ctx.nav_flash_bg,
      ctx.editor_bg,
      ctx.gutter_colors,
      ctx.git_colors,
      ctx.whitespace_face,
      ctx.search_colors,
      ctx.document_highlight_colors,
      ctx.wrap_on,
      ctx.line_number_style,
      Minga.Core.WidthOracle.fingerprint(ctx.width_oracle),
      ctx.indent_guide_face,
      ctx.indent_guide_active_face,
      ctx.hl_todo_faces,
      ctx.cursor_col,
      ctx.cursor_line
    }
  end

  @spec highlight_fingerprint(Highlight.t() | nil) :: integer() | nil
  defp highlight_fingerprint(nil), do: nil

  defp highlight_fingerprint(%Highlight{} = highlight) do
    :erlang.phash2(highlight)
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec cursor_display_col([String.t()], Buffer.position(), non_neg_integer()) ::
          non_neg_integer()
  defp cursor_display_col(lines, {line, byte_col}, first_line) do
    line_text = cursor_line_text(lines, line, first_line)
    Unicode.display_col(line_text, byte_col)
  end

  @spec invisible_char_settings(%{atom() => term()}, MingaEditor.UI.Theme.t()) ::
          {boolean(), pos_integer(), Face.t() | nil}
  defp invisible_char_settings(options, theme) when is_map(options) do
    show = Map.get(options, :show_invisible, false)
    tab_w = Map.get(options, :tab_width, 2)

    face =
      if show do
        fg = theme.editor.whitespace_fg || theme.gutter.fg
        Face.new(fg: fg)
      else
        nil
      end

    {show, tab_w, face}
  end

  @spec byte_col_to_display(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp byte_col_to_display(lines, line, byte_col, first_line) do
    line_text = cursor_line_text(lines, line, first_line)
    Unicode.display_col(line_text, byte_col)
  end

  @spec byte_col_to_display_end(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp byte_col_to_display_end(lines, line, byte_col, first_line) do
    line_text = cursor_line_text(lines, line, first_line)
    next_byte = Unicode.next_grapheme_byte_offset(line_text, byte_col)
    Unicode.display_col(line_text, next_byte)
  end

  @spec sort_positions(Buffer.position(), Buffer.position()) ::
          {Buffer.position(), Buffer.position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @spec cursor_line_text([String.t()], non_neg_integer(), non_neg_integer()) :: String.t()
  defp cursor_line_text(lines, cursor_line, first_line) do
    index = cursor_line - first_line

    if index >= 0 and index < Enum.count(lines) do
      Enum.at(lines, index)
    else
      ""
    end
  end
end
