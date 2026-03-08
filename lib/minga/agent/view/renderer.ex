defmodule Minga.Agent.View.Renderer do
  @moduledoc """
  Full-screen agentic view renderer (OpenCode-style layout).

  Layout from top to bottom:

      Row 0          Title bar (status, model, session info, token usage)
      Row 1..H-6     Chat messages (left ~65%) │ File viewer (right ~35%)
      Row H-5        Input border ─── Prompt ─── (full width)
      Row H-4        Input text (full width)
      Row H-3        Input padding (full width)
      Row H-2        Modeline (full width)
      Row H-1        Minibuffer (reserved by editor)

  The chat panel has no internal header or input; those are rendered at
  full width by this module. The file viewer has a header bar at the top
  of its rect showing the filename.

  Called by `Minga.Editor.RenderPipeline` when `state.agentic.active` is true.
  Returns `DisplayList.draw()` tuples.
  """

  alias Minga.Agent.ChatRenderer
  alias Minga.Agent.DiffRenderer
  alias Minga.Agent.ModelLimits
  alias Minga.Agent.Session
  alias Minga.Agent.View.DirectoryRenderer
  alias Minga.Agent.View.Help
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.ShellRenderer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.DisplayList
  alias Minga.Editor.Modeline
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.Line, as: LineRenderer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Theme

  @typedoc "Screen rectangle {row_offset, col_offset, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @max_input_lines 8

  # ── Focused input type ─────────────────────────────────────────────────────

  defmodule RenderInput do
    @moduledoc """
    Focused input for the agentic view renderer.

    Contains exactly the data needed to render the full-screen agent view,
    without requiring a full `EditorState`. This enables isolated testing
    and makes the data dependency graph explicit.
    """

    alias Minga.Agent.View.Preview
    alias Minga.Editor.Viewport
    alias Minga.Highlight
    alias Minga.Theme

    @enforce_keys [:viewport, :theme, :agent_status, :panel, :agentic]
    defstruct [
      :viewport,
      :theme,
      :agent_status,
      :panel,
      :agentic,
      messages: [],
      usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0},
      preview: Preview.new(),
      buffer_snapshot: nil,
      highlight: nil,
      mode: :normal,
      mode_state: nil,
      buf_index: 1,
      buf_count: 1,
      pending_approval: nil
    ]

    @type t :: %__MODULE__{
            viewport: Viewport.t(),
            theme: Theme.t(),
            agent_status: atom() | nil,
            panel: panel_data(),
            agentic: agentic_data(),
            messages: list(),
            usage: map(),
            preview: Preview.t(),
            buffer_snapshot: map() | nil,
            highlight: Highlight.t() | nil,
            mode: atom(),
            mode_state: term(),
            buf_index: pos_integer(),
            buf_count: pos_integer(),
            pending_approval: map() | nil
          }

    @typedoc "Agent panel fields needed for rendering."
    @type panel_data :: %{
            input_focused: boolean(),
            input_lines: [String.t()],
            input_cursor: {non_neg_integer(), non_neg_integer()},
            scroll_offset: non_neg_integer(),
            spinner_frame: non_neg_integer(),
            model_name: String.t(),
            thinking_level: String.t(),
            auto_scroll: boolean(),
            display_start_index: non_neg_integer(),
            mention_completion: Minga.Agent.FileMention.completion() | nil
          }

    @typedoc "Agentic view fields needed for rendering."
    @type agentic_data :: %{
            chat_width_pct: non_neg_integer(),
            help_visible: boolean(),
            focus: atom(),
            search: Minga.Agent.View.State.search_state() | nil,
            toast: Minga.Agent.View.State.toast() | nil
          }
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Renders the full-screen agentic view from a focused `RenderInput`.

  Preferred entry point for the pipeline. No GenServer calls are made;
  all data is pre-fetched in the input.
  """
  @spec render(RenderInput.t()) :: [DisplayList.draw()]
  def render(%RenderInput{} = input) do
    cols = input.viewport.cols
    rows = input.viewport.rows

    input_height = compute_input_height(input.panel.input_lines)
    panel_end = rows - 1 - 1 - input_height
    panel_start = 1
    panel_height = max(panel_end - panel_start, 1)

    chat_width_pct = input.agentic.chat_width_pct
    chat_width = max(div(cols * chat_width_pct, 100), 20)
    separator_col = chat_width
    viewer_col = chat_width + 1
    viewer_width = max(cols - viewer_col, 10)

    input_row = panel_end
    modeline_row = input_row + input_height

    title_commands = render_title_bar_from_input(input, 0, cols)
    chat_commands = render_chat_from_input(input, {panel_start, 0, chat_width, panel_height})

    separator_commands =
      render_separator(separator_col, panel_start, panel_height, input.theme)

    viewer_commands =
      render_file_viewer_from_input(
        input,
        {panel_start, viewer_col, viewer_width, panel_height}
      )

    input_commands = render_input_from_input(input, input_row, cols)
    modeline_commands = render_modeline_from_input(input, modeline_row, cols)

    base =
      title_commands ++
        chat_commands ++
        separator_commands ++
        viewer_commands ++
        input_commands ++
        modeline_commands

    overlays =
      if input.agentic.help_visible do
        render_help_overlay(input, cols, rows)
      else
        []
      end

    toast_cmds = render_toast_overlay(input, cols)

    base ++ overlays ++ toast_cmds
  end

  # Legacy wrapper: extracts a RenderInput from full EditorState.
  @spec render(state()) :: [DisplayList.draw()]
  def render(%EditorState{} = state) do
    input = extract_input(state)
    render(input)
  end

  @doc """
  Returns `{row, col}` for where the terminal cursor should be placed.

  When the chat input is focused the cursor sits in the full-width input area.
  Otherwise the cursor is hidden off-screen.
  """
  @spec cursor_position(state()) :: {non_neg_integer(), non_neg_integer()}
  def cursor_position(state) do
    rows = state.viewport.rows

    if state.agent.panel.input_focused do
      panel = state.agent.panel
      {cursor_line, cursor_col} = panel.input_cursor
      visible_lines = min(length(panel.input_lines), @max_input_lines)
      input_height = visible_lines + 2
      panel_end = rows - 1 - 1 - input_height
      input_text_row = panel_end + 1 + min(cursor_line, visible_lines - 1)
      input_col = 2 + cursor_col
      {input_text_row, input_col}
    else
      {rows, 0}
    end
  end

  # ── Input extraction ────────────────────────────────────────────────────────

  @spec extract_input(state()) :: RenderInput.t()
  defp extract_input(state) do
    agent = state.agent
    panel = agent.panel

    messages =
      if agent.session do
        try do
          Session.messages(agent.session)
        catch
          :exit, _ -> []
        end
      else
        []
      end

    usage =
      if agent.session do
        try do
          Session.usage(agent.session)
        catch
          :exit, _ -> empty_usage()
        end
      else
        empty_usage()
      end

    # Pre-fetch buffer snapshot for file viewer
    scroll = state.agentic.preview.scroll_offset
    rows = state.viewport.rows
    input_h = compute_input_height(state.agent.panel.input_lines)
    content_rows = max(rows - 1 - 1 - input_h - 1 - 1, 1)

    buffer_snapshot =
      case state.buffers.active do
        nil ->
          nil

        buf ->
          snapshot = BufferServer.render_snapshot(buf, scroll, content_rows)
          %{snapshot | name: snapshot_display_name(snapshot)}
      end

    highlight =
      if state.highlight.current.capture_names != [], do: state.highlight.current, else: nil

    %RenderInput{
      viewport: state.viewport,
      theme: state.theme,
      agent_status: agent.status,
      panel: %{
        input_focused: panel.input_focused,
        input_lines: panel.input_lines,
        input_cursor: panel.input_cursor,
        scroll_offset: panel.scroll_offset,
        spinner_frame: panel.spinner_frame,
        model_name: panel.model_name,
        thinking_level: panel.thinking_level,
        auto_scroll: panel.auto_scroll,
        display_start_index: panel.display_start_index,
        mention_completion: panel.mention_completion
      },
      agentic: %{
        chat_width_pct: state.agentic.chat_width_pct,
        help_visible: state.agentic.help_visible,
        focus: state.agentic.focus,
        search: state.agentic.search,
        toast: state.agentic.toast
      },
      messages: messages,
      usage: usage,
      preview: state.agentic.preview,
      buffer_snapshot: buffer_snapshot,
      highlight: highlight,
      mode: state.mode,
      mode_state: state.mode_state,
      buf_index: state.buffers.active_index + 1,
      buf_count: length(state.buffers.list),
      pending_approval: state.agent.pending_approval
    }
  end

  # ── Title bar ───────────────────────────────────────────────────────────────

  @spec render_title_bar_from_input(RenderInput.t(), non_neg_integer(), pos_integer()) ::
          [DisplayList.draw()]
  defp render_title_bar_from_input(input, row, cols) do
    at = Theme.agent_theme(input.theme)
    panel = input.panel

    status_icon = status_icon(input.agent_status, panel.spinner_frame)
    status_fg = status_fg(input.agent_status, at)

    usage_text = format_usage(input.usage)
    context_text = format_context_bar(input.usage, panel.model_name)

    left = " #{status_icon}  󰚩 #{panel.model_name}"
    center = "Minga Agent"

    right_parts = [context_text, usage_text] |> Enum.reject(&(&1 == "")) |> Enum.join("  ")
    right = if right_parts != "", do: "#{right_parts} ", else: ""

    left_len = String.length(left)
    center_len = String.length(center)
    right_len = String.length(right)

    center_start = max(div(cols - center_len, 2), left_len + 3)
    gap_left = center_start - left_len
    gap_right = max(cols - center_start - center_len - right_len, 0)

    bar_text =
      left <>
        String.duplicate("─", max(gap_left - 2, 1)) <>
        " " <>
        center <>
        " " <>
        String.duplicate("─", max(gap_right - 1, 1)) <>
        right

    bar_text = String.slice(bar_text, 0, cols) |> String.pad_trailing(cols)

    cmds = [
      DisplayList.draw(row, 0, bar_text, fg: at.panel_border, bg: at.header_bg),
      DisplayList.draw(row, 1, status_icon, fg: status_fg, bg: at.header_bg, bold: true),
      DisplayList.draw(row, center_start, center,
        fg: at.header_fg,
        bg: at.header_bg,
        bold: true
      )
    ]

    # Overlay the context bar with colored segments
    context_bar_cmds =
      render_context_bar_overlay(row, cols, right_len, input.usage, panel.model_name, at)

    cmds ++ context_bar_cmds
  end

  # ── Chat panel (messages only) ──────────────────────────────────────────────

  @spec render_chat_from_input(RenderInput.t(), rect()) :: [DisplayList.draw()]
  defp render_chat_from_input(input, rect) do
    panel_state = %{
      messages: input.messages,
      status: input.agent_status || :idle,
      input_lines: input.panel.input_lines,
      input_cursor: input.panel.input_cursor,
      scroll_offset: input.panel.scroll_offset,
      spinner_frame: input.panel.spinner_frame,
      usage: input.usage,
      model_name: input.panel.model_name,
      thinking_level: input.panel.thinking_level,
      auto_scroll: input.panel.auto_scroll,
      display_start_index: input.panel.display_start_index,
      error_message: nil,
      pending_approval: input.pending_approval,
      mention_completion: input.panel.mention_completion
    }

    ChatRenderer.render_messages_only(rect, panel_state, input.theme)
  end

  # ── Vertical separator ──────────────────────────────────────────────────────

  @spec render_separator(non_neg_integer(), non_neg_integer(), pos_integer(), Theme.t()) ::
          [DisplayList.draw()]
  defp render_separator(col, start_row, height, theme) do
    at = Theme.agent_theme(theme)

    for row <- start_row..(start_row + height - 1) do
      DisplayList.draw(row, col, "│", fg: at.panel_border, bg: at.panel_bg)
    end
  end

  # ── File viewer panel ───────────────────────────────────────────────────────

  @spec render_file_viewer_from_input(RenderInput.t(), rect()) :: [DisplayList.draw()]

  defp render_file_viewer_from_input(input, rect) do
    render_preview(input, rect)
  end

  # ── Preview content dispatch ────────────────────────────────────────────────

  @spec render_preview(RenderInput.t(), rect()) :: [DisplayList.draw()]

  defp render_preview(%{preview: %Preview{content: {:diff, review}}} = input, rect) do
    DiffRenderer.render(rect, review, input.theme)
  end

  defp render_preview(
         %{preview: %Preview{content: {:shell, cmd, output, status}, scroll_offset: scroll}} =
           input,
         rect
       ) do
    spinner = input.panel.spinner_frame
    ShellRenderer.render(rect, cmd, output, status, scroll, spinner, input.theme)
  end

  defp render_preview(
         %{preview: %Preview{content: {:file, path, content}, scroll_offset: scroll}} = input,
         {row_off, col_off, width, height}
       ) do
    render_file_preview(input, path, content, scroll, {row_off, col_off, width, height})
  end

  defp render_preview(
         %{preview: %Preview{content: {:directory, path, entries}, scroll_offset: scroll}} =
           input,
         rect
       ) do
    DirectoryRenderer.render(rect, path, entries, scroll, input.theme)
  end

  defp render_preview(%{buffer_snapshot: nil}, {row_off, col_off, width, height}) do
    render_empty_preview({row_off, col_off, width, height})
  end

  defp render_preview(input, {row_off, col_off, width, height}) do
    render_buffer_preview(input, {row_off, col_off, width, height})
  end

  # ── Empty preview ───────────────────────────────────────────────────────────

  @spec render_empty_preview(rect()) :: [DisplayList.draw()]
  defp render_empty_preview({row_off, col_off, width, height}) do
    blank = String.duplicate(" ", width)

    for row <- 0..(height - 1) do
      DisplayList.draw(row_off + row, col_off, blank)
    end
  end

  # ── File content preview ────────────────────────────────────────────────────

  @spec render_file_preview(RenderInput.t(), String.t(), String.t(), non_neg_integer(), rect()) ::
          [DisplayList.draw()]
  defp render_file_preview(input, path, content, scroll, {row_off, col_off, width, height}) do
    at = Theme.agent_theme(input.theme)
    lines = String.split(content, "\n")
    total = length(lines)

    content_start = row_off + 1
    content_rows = max(height - 1, 1)
    scroll_clamped = min(scroll, max(total - content_rows, 0))
    visible = Enum.slice(lines, scroll_clamped, content_rows)

    gutter_w = file_viewer_gutter_width(total)
    content_w = max(width - gutter_w, 1)

    # Header
    display_name = Path.basename(path)
    header_text = String.pad_trailing(" 📄 #{display_name} (read_file)", width)
    header = DisplayList.draw(row_off, col_off, header_text, fg: at.header_fg, bg: at.header_bg)

    # Content lines
    line_cmds =
      visible
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, idx} ->
        row = content_start + idx
        line_num = scroll_clamped + idx + 1
        gutter_text = String.pad_leading("#{line_num}", gutter_w - 1) <> " "
        line_text = String.slice(line, 0, content_w)
        blank = String.duplicate(" ", width)

        [
          DisplayList.draw(row, col_off, blank, bg: at.panel_bg),
          DisplayList.draw(row, col_off, gutter_text, fg: at.tool_border, bg: at.panel_bg),
          DisplayList.draw(row, col_off + gutter_w, line_text, fg: at.text_fg, bg: at.panel_bg)
        ]
      end)

    # Fill remaining rows
    rendered = length(visible)

    tilde_cmds =
      if rendered < content_rows do
        blank = String.duplicate(" ", width)

        for r <- (content_start + rendered)..(content_start + content_rows - 1) do
          DisplayList.draw(r, col_off, blank, bg: at.panel_bg)
        end
      else
        []
      end

    [header | line_cmds] ++ tilde_cmds
  end

  # ── Buffer snapshot preview (legacy fallback) ───────────────────────────────

  @spec render_buffer_preview(RenderInput.t(), rect()) :: [DisplayList.draw()]
  defp render_buffer_preview(input, {row_off, col_off, width, height}) do
    snapshot = input.buffer_snapshot
    scroll = input.preview.scroll_offset

    content_start = row_off + 1
    content_rows = max(height - 1, 1)

    lines = snapshot.lines
    line_count = snapshot.line_count

    abs_gutter_col = max(col_off, 0)
    local_gutter_w = file_viewer_gutter_width(line_count)
    abs_content_col = col_off + local_gutter_w
    content_w = max(width - local_gutter_w, 1)

    viewer_vp = Viewport.new(content_rows, width)
    viewer_vp = %{viewer_vp | top: scroll}

    render_ctx = %Context{
      viewport: viewer_vp,
      visual_selection: nil,
      search_matches: [],
      gutter_w: abs_content_col,
      content_w: content_w,
      confirm_match: nil,
      highlight: input.highlight,
      has_sign_column: false,
      diagnostic_signs: %{},
      git_signs: %{},
      search_colors: input.theme.search,
      gutter_colors: input.theme.gutter,
      git_colors: input.theme.git
    }

    {gutter_cmds, line_cmds, _} =
      Enum.reduce(
        Enum.with_index(lines),
        {[], [], snapshot.first_line_byte_offset},
        fn {line_text, screen_row}, {gutters, contents, byte_offset} ->
          buf_line = max(scroll + screen_row, 0)
          abs_row = max(content_start + screen_row, 0)

          gutter_cmd =
            Gutter.render_number(
              abs_row,
              abs_gutter_col,
              buf_line,
              0,
              local_gutter_w,
              :absolute,
              render_ctx.gutter_colors
            )

          content_cmds =
            LineRenderer.render(line_text, abs_row, buf_line, render_ctx, byte_offset)

          next_offset = byte_offset + byte_size(line_text) + 1

          {gutters ++ List.wrap(gutter_cmd), contents ++ content_cmds, next_offset}
        end
      )

    tilde_cmds =
      if length(lines) < content_rows do
        tilde_start = content_start + length(lines)
        tilde_end = content_start + content_rows - 1

        for r <- tilde_start..tilde_end do
          DisplayList.draw(r, abs_content_col, "~", fg: input.theme.editor.tilde_fg)
        end
      else
        []
      end

    at = Theme.agent_theme(input.theme)
    file_name = Map.get(snapshot, :name, "[No Name]")
    header_text = String.pad_trailing(" 📄 #{file_name}", width)

    header_cmd =
      DisplayList.draw(row_off, col_off, header_text, fg: at.header_fg, bg: at.header_bg)

    [header_cmd | gutter_cmds] ++ line_cmds ++ tilde_cmds
  end

  # ── Full-width input area ───────────────────────────────────────────────────

  @spec render_input_from_input(RenderInput.t(), non_neg_integer(), pos_integer()) ::
          [DisplayList.draw()]
  defp render_input_from_input(input, row, cols) do
    at = Theme.agent_theme(input.theme)
    panel = input.panel

    label = "─── Prompt "
    border_rest = String.duplicate("─", max(cols - String.length(label), 0))
    border = label <> border_rest
    border_cmd = DisplayList.draw(row, 0, border, fg: at.input_border, bg: at.panel_bg)

    blank = String.duplicate(" ", cols)
    is_empty = panel.input_lines == [""]
    visible_lines = min(length(panel.input_lines), @max_input_lines)

    line_cmds =
      if is_empty do
        input_row = row + 1
        blank_cmd = DisplayList.draw(input_row, 0, blank, bg: at.input_bg)
        placeholder = String.slice("  Type a message, Enter to send", 0, cols)

        text_cmd =
          DisplayList.draw(input_row, 0, placeholder, fg: at.input_placeholder, bg: at.input_bg)

        [blank_cmd, text_cmd]
      else
        # Render visible input lines (scroll to keep cursor visible)
        {cursor_line, _cursor_col} = panel.input_cursor
        total_lines = length(panel.input_lines)
        scroll = input_scroll_offset(cursor_line, visible_lines, total_lines)

        panel.input_lines
        |> Enum.drop(scroll)
        |> Enum.take(visible_lines)
        |> Enum.with_index()
        |> Enum.flat_map(fn {line_text, idx} ->
          r = row + 1 + idx
          blank_cmd = DisplayList.draw(r, 0, blank, bg: at.input_bg)
          display = String.slice("  " <> line_text, 0, cols)
          text_cmd = DisplayList.draw(r, 0, display, fg: at.text_fg, bg: at.input_bg)
          [blank_cmd, text_cmd]
        end)
      end

    # Bottom padding
    pad_row = row + 1 + visible_lines
    pad_cmd = DisplayList.draw(pad_row, 0, blank, bg: at.input_bg)

    [border_cmd | line_cmds] ++ [pad_cmd]
  end

  # Computes the dynamic input area height: border(1) + visible lines + padding(1).
  @spec compute_input_height([String.t()]) :: pos_integer()
  defp compute_input_height(input_lines) do
    visible = min(length(input_lines), @max_input_lines)
    visible + 2
  end

  # Computes scroll offset to keep the cursor visible within the input area.
  @spec input_scroll_offset(non_neg_integer(), pos_integer(), pos_integer()) ::
          non_neg_integer()
  defp input_scroll_offset(cursor_line, visible_lines, total_lines) do
    max_scroll = max(total_lines - visible_lines, 0)
    # Keep cursor within the visible window
    min(max(cursor_line - visible_lines + 1, 0), max_scroll)
  end

  # ── Modeline ────────────────────────────────────────────────────────────────

  @spec render_modeline_from_input(RenderInput.t(), non_neg_integer(), pos_integer()) ::
          [DisplayList.draw()]
  defp render_modeline_from_input(input, row, cols) do
    case input.agentic.search do
      %{input_active: true} = search ->
        render_search_prompt(row, cols, search, input.theme)

      %{input_active: false} = search ->
        # Show match count in modeline when search is confirmed
        render_search_modeline(row, cols, search, input)

      nil ->
        render_agent_modeline(row, cols, input)
    end
  end

  @spec render_agent_modeline(non_neg_integer(), pos_integer(), RenderInput.t()) :: [
          DisplayList.draw()
        ]
  defp render_agent_modeline(row, cols, input) do
    Modeline.render(
      row,
      cols,
      %{
        mode: input.mode,
        mode_state: input.mode_state,
        mode_override: "AGENT",
        file_name: "AGENT",
        filetype: :text,
        dirty_marker: "",
        cursor_line: 0,
        cursor_col: 0,
        line_count: 0,
        buf_index: input.buf_index,
        buf_count: input.buf_count,
        macro_recording: false,
        agent_status: input.agent_status,
        agent_theme_colors: Theme.agent_theme(input.theme)
      },
      input.theme
    )
  end

  @spec render_search_prompt(non_neg_integer(), pos_integer(), map(), Theme.t()) :: [
          DisplayList.draw()
        ]
  defp render_search_prompt(row, cols, search, theme) do
    at = Theme.agent_theme(theme)
    match_count = length(search.matches)
    current = search.current + 1

    suffix =
      if match_count > 0 do
        " (#{current}/#{match_count})"
      else
        ""
      end

    prompt = "/#{search.query}#{suffix}"
    padded = String.pad_trailing(prompt, cols)
    [DisplayList.draw(row, 0, padded, fg: at.text_fg, bg: at.input_bg)]
  end

  @spec render_search_modeline(non_neg_integer(), pos_integer(), map(), RenderInput.t()) :: [
          DisplayList.draw()
        ]
  defp render_search_modeline(row, cols, search, input) do
    modeline_cmds = render_agent_modeline(row, cols, input)
    match_count = length(search.matches)
    current = search.current + 1
    indicator = " [#{current}/#{match_count} \"#{search.query}\"]"
    at = Theme.agent_theme(input.theme)
    indicator_col = max(cols - String.length(indicator), 0)

    overlay =
      DisplayList.draw(row, indicator_col, indicator,
        fg: at.status_thinking,
        bg: input.theme.modeline.normal_bg
      )

    modeline_cmds ++ [overlay]
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec status_icon(atom() | nil, non_neg_integer()) :: String.t()
  defp status_icon(:thinking, frame), do: spinner(frame)
  defp status_icon(:tool_executing, _), do: "⚡"
  defp status_icon(:error, _), do: "✗"
  defp status_icon(_, _), do: "◯"

  @spec status_fg(atom() | nil, map()) :: non_neg_integer()
  defp status_fg(:idle, at), do: at.status_idle
  defp status_fg(:thinking, at), do: at.status_thinking
  defp status_fg(:tool_executing, at), do: at.status_tool
  defp status_fg(:error, at), do: at.status_error
  defp status_fg(_, at), do: at.status_idle

  @spec file_viewer_gutter_width(non_neg_integer()) :: non_neg_integer()
  defp file_viewer_gutter_width(line_count) do
    digits = line_count |> max(1) |> Integer.digits() |> length()
    digits + 1
  end

  @spec snapshot_display_name(map()) :: String.t()
  defp snapshot_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp snapshot_display_name(_), do: "[No Name]"

  @spec empty_usage() :: map()
  defp empty_usage, do: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}

  @spec format_usage(map()) :: String.t()
  defp format_usage(%{input: i, output: o, cost: c}) when i > 0 do
    "↑#{format_tokens(i)} ↓#{format_tokens(o)} $#{Float.round(c, 3)}"
  end

  defp format_usage(_), do: ""

  @spec format_tokens(non_neg_integer()) :: String.t()
  defp format_tokens(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_tokens(n), do: "#{n}"

  # ── Context bar ─────────────────────────────────────────────────────────────

  @context_bar_width 10

  @doc false
  @spec context_fill_pct(map(), String.t()) :: non_neg_integer() | nil
  def context_fill_pct(usage, model_name) do
    limit = ModelLimits.context_limit(model_name)

    case limit do
      nil ->
        nil

      0 ->
        nil

      n ->
        used = Map.get(usage, :input, 0) + Map.get(usage, :output, 0)
        min(round(used / n * 100), 100)
    end
  end

  # Formats the context bar as plain text for title bar layout measurement.
  @spec format_context_bar(map(), String.t()) :: String.t()
  defp format_context_bar(usage, model_name) do
    case context_fill_pct(usage, model_name) do
      nil -> ""
      pct -> context_bar_text(pct)
    end
  end

  @spec context_bar_text(non_neg_integer()) :: String.t()
  defp context_bar_text(pct) do
    filled = div(pct * @context_bar_width, 100)
    empty = @context_bar_width - filled
    "[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}] #{pct}%"
  end

  # Renders colored overlay draw commands for the context bar.
  # The bar is already placed as plain text in the title bar string;
  # we overlay it with the correct color based on fill percentage.
  @spec render_context_bar_overlay(
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          map(),
          String.t(),
          Theme.Agent.t()
        ) :: [DisplayList.draw()]
  defp render_context_bar_overlay(row, cols, right_len, usage, model_name, at) do
    case context_fill_pct(usage, model_name) do
      nil ->
        []

      pct ->
        bar = context_bar_text(pct)
        bar_col = cols - right_len
        color = context_color(pct, at)
        [DisplayList.draw(row, bar_col, bar, fg: color, bg: at.header_bg)]
    end
  end

  @spec context_color(non_neg_integer(), Theme.Agent.t()) :: Theme.color()
  defp context_color(pct, at) when pct > 80, do: at.context_high
  defp context_color(pct, at) when pct > 50, do: at.context_mid
  defp context_color(_pct, at), do: at.context_low

  @spec spinner(non_neg_integer()) :: String.t()
  defp spinner(frame) do
    chars = ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    Enum.at(chars, rem(frame, length(chars)))
  end

  # ── Toast overlay ─────────────────────────────────────────────────────────

  @spec render_toast_overlay(RenderInput.t(), pos_integer()) :: [DisplayList.draw()]
  defp render_toast_overlay(%{agentic: %{toast: nil}}, _cols), do: []

  defp render_toast_overlay(%{agentic: %{toast: toast}} = input, cols) do
    at = Theme.agent_theme(input.theme)
    text = " #{toast.icon} #{toast.message} "
    text_len = String.length(text)
    col = max(cols - text_len - 1, 0)

    fg = toast_fg(toast.level, at)
    bg = toast_bg(toast.level, at)

    [DisplayList.draw(0, col, text, fg: fg, bg: bg)]
  end

  @spec toast_fg(atom(), Theme.Agent.t()) :: Theme.color()
  defp toast_fg(:error, at), do: at.status_error
  defp toast_fg(:warning, at), do: at.status_thinking
  defp toast_fg(:info, at), do: at.status_idle

  @spec toast_bg(atom(), Theme.Agent.t()) :: Theme.color()
  defp toast_bg(_level, at), do: at.header_bg

  # ── Help overlay ──────────────────────────────────────────────────────────

  @spec render_help_overlay(RenderInput.t(), pos_integer(), pos_integer()) :: [DisplayList.draw()]
  defp render_help_overlay(input, cols, rows) do
    at = Theme.agent_theme(input.theme)

    groups =
      case input.agentic.focus do
        :file_viewer -> Help.viewer_bindings()
        _ -> Help.chat_bindings()
      end

    context_label =
      case input.agentic.focus do
        :file_viewer -> "File Viewer"
        _ -> "Chat"
      end

    content_lines = help_content_lines(groups)

    box_width = min(max(div(cols * 60, 100), 40), cols - 4)
    box_height = min(length(content_lines) + 4, rows - 4)
    start_col = div(cols - box_width, 2)
    start_row = div(rows - box_height, 2)
    key_col_width = 20

    border_top = "┌" <> String.duplicate("─", box_width - 2) <> "┐"
    border_bottom = "└" <> String.duplicate("─", box_width - 2) <> "┘"
    blank_line = "│" <> String.duplicate(" ", box_width - 2) <> "│"

    # Top border
    commands = [
      DisplayList.draw(start_row, start_col, border_top, fg: at.panel_border, bg: at.panel_bg)
    ]

    # Title row
    title = " Keybindings (#{context_label}) "
    title_pad = String.duplicate(" ", max(box_width - 2 - String.length(title), 0))

    commands = [
      DisplayList.draw(start_row + 1, start_col, "│#{title}#{title_pad}│",
        fg: at.assistant_label,
        bg: at.panel_bg,
        bold: true
      )
      | commands
    ]

    # Separator
    sep = "├" <> String.duplicate("─", box_width - 2) <> "┤"

    commands = [
      DisplayList.draw(start_row + 2, start_col, sep, fg: at.panel_border, bg: at.panel_bg)
      | commands
    ]

    # Content rows
    visible_lines = Enum.take(content_lines, box_height - 4)

    commands =
      visible_lines
      |> Enum.with_index(3)
      |> Enum.reduce(commands, fn {{type, left, right}, row_offset}, acc ->
        row = start_row + row_offset

        {line, style} =
          help_line_content(type, left, right, box_width, key_col_width, blank_line, at)

        [DisplayList.draw(row, start_col, line, style) | acc]
      end)

    # Bottom border
    bottom_row = start_row + length(visible_lines) + 3

    [
      DisplayList.draw(bottom_row, start_col, border_bottom, fg: at.panel_border, bg: at.panel_bg)
      | commands
    ]
  end

  @spec help_line_content(
          atom(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t(),
          Theme.Agent.t()
        ) ::
          {String.t(), keyword()}
  defp help_line_content(:header, left, _right, box_width, _key_w, _blank, at) do
    text = " #{left} "
    pad = String.duplicate(" ", max(box_width - 2 - String.length(text), 0))
    {"│#{text}#{pad}│", [fg: at.assistant_label, bg: at.panel_bg, bold: true]}
  end

  defp help_line_content(:binding, left, right, box_width, key_w, _blank, at) do
    key_text = String.pad_trailing(left, key_w)
    desc_space = max(box_width - 2 - key_w - 2, 1)
    desc_text = String.slice(right, 0, desc_space)
    desc_pad = String.duplicate(" ", max(desc_space - String.length(desc_text), 0))
    {"│ #{key_text}#{desc_text}#{desc_pad} │", [fg: at.text_fg, bg: at.panel_bg]}
  end

  defp help_line_content(:spacer, _left, _right, _box_width, _key_w, blank, at) do
    {blank, [fg: at.panel_border, bg: at.panel_bg]}
  end

  @typedoc "Help content line type."
  @type help_line ::
          {:header, String.t(), String.t()}
          | {:binding, String.t(), String.t()}
          | {:spacer, String.t(), String.t()}

  @spec help_content_lines([Help.group()]) :: [help_line()]
  defp help_content_lines(groups) do
    Enum.flat_map(groups, fn {category, bindings} ->
      header = [{:header, category, ""}]
      items = Enum.map(bindings, fn {key, desc} -> {:binding, key, desc} end)
      header ++ items ++ [{:spacer, "", ""}]
    end)
  end
end
