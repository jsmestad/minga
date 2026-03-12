defmodule Minga.Agent.View.Renderer do
  @moduledoc """
  Full-screen agentic view renderer (OpenCode-style layout).

  Layout from top to bottom:

      Row 0          Tab bar (rendered by TabBarRenderer)
      Row 1          Title bar (status, model, session info, token usage)
      Row 2..H-2     Left column: Chat + Input │ Right column: Preview/Dashboard
        Left:          Chat messages (rows 2..H-2-input_h)
                       Input border + text + model info (bottom of left col)
        Right:         Preview or dashboard (full column height)
        Separator:     Vertical │ (full column height)
      Row H-2        Modeline (full width)
      Row H-1        Minibuffer (reserved by editor)

  The two-column split extends the full height between title bar and
  modeline. The input area renders within the left column only, not at
  full width. The right panel (preview/dashboard) extends alongside the
  input area. This matches the OpenCode reference layout.

  Called by `Minga.Editor.RenderPipeline` when the active surface is `AgentView`.
  Returns `DisplayList.draw()` tuples.
  """

  alias Minga.Agent.ChatRenderer
  alias Minga.Agent.DiffRenderer
  alias Minga.Agent.ModelLimits
  alias Minga.Agent.PanelState
  alias Minga.Agent.Session
  alias Minga.Agent.View.DirectoryRenderer
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.ShellRenderer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.DisplayList
  alias Minga.Editor.Modeline
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.Line, as: LineRenderer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.Viewport

  alias Minga.Input.Wrap, as: InputWrap
  alias Minga.Keymap.Scope
  alias Minga.Scroll
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
      pending_approval: nil,
      session_title: "Minga Agent",
      lsp_servers: []
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
            pending_approval: map() | nil,
            session_title: String.t(),
            lsp_servers: [atom()]
          }

    @typedoc "Agent panel fields needed for rendering."
    @type panel_data :: %{
            input_focused: boolean(),
            input_lines: [String.t()],
            input_cursor: {non_neg_integer(), non_neg_integer()},
            mode: atom(),
            mode_state: term(),
            scroll: Scroll.t(),
            spinner_frame: non_neg_integer(),
            model_name: String.t(),
            provider_name: String.t(),
            thinking_level: String.t(),
            display_start_index: non_neg_integer(),
            mention_completion: Minga.Agent.FileMention.completion() | nil,
            pasted_blocks: [PanelState.paste_block()]
          }

    @typedoc "Agentic view fields needed for rendering."
    @type agentic_data :: %{
            chat_width_pct: non_neg_integer(),
            help_visible: boolean(),
            focus: atom(),
            search: Minga.Agent.View.State.search_state() | nil,
            toast: Minga.Agent.View.State.toast() | nil,
            context_estimate: non_neg_integer()
          }
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Renders the full-screen agentic view from a focused `RenderInput`.

  Preferred entry point for the pipeline. No GenServer calls are made;
  all data is pre-fetched in the input.
  """
  @spec render(RenderInput.t()) :: {[DisplayList.draw()], scroll_metrics()}
  def render(%RenderInput{} = input) do
    cols = input.viewport.cols
    rows = input.viewport.rows

    # Compute chat_width first so we can derive inner_width for soft-wrap height.
    chat_width_pct = input.agentic.chat_width_pct
    chat_width = max(div(cols * chat_width_pct, 100), 20)

    input_height =
      compute_input_height(input.panel.input_lines, input_inner_width(chat_width))

    # Tab bar at row 0, title bar at row 1, content starts at row 2.
    # Modeline at rows-2, minibuffer at rows-1.
    panel_start = 2
    modeline_row = rows - 1 - 1

    # The two-column split extends from panel_start to just above the modeline.
    panel_height = max(modeline_row - panel_start, 1)

    # Left column is split: chat on top, input at bottom.
    chat_height = max(panel_height - input_height, 1)
    input_row = panel_start + chat_height
    separator_col = chat_width
    viewer_col = chat_width + 1
    viewer_width = max(cols - viewer_col, 10)

    title_commands = render_title_bar_from_input(input, 1, cols)

    # Left column: chat messages fill the top portion.
    {chat_commands, chat_metrics} =
      render_chat_from_input(input, {panel_start, 0, chat_width, chat_height})

    # Separator and right column span the FULL panel height (alongside input).
    separator_commands =
      render_separator(separator_col, panel_start, panel_height, input.theme)

    viewer_commands =
      render_file_viewer_from_input(
        input,
        {panel_start, viewer_col, viewer_width, panel_height}
      )

    # Input area renders within the left column only.
    input_commands = render_input_from_input(input, input_row, chat_width)
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

    {base ++ overlays ++ toast_cmds, chat_metrics}
  end

  # Legacy wrapper: extracts a RenderInput from full EditorState.
  @spec render(state()) :: {[DisplayList.draw()], scroll_metrics()}
  def render(%EditorState{} = state) do
    input = extract_input(state)
    render(input)
  end

  @doc """
  Renders agent chat content within a bounded window rect.

  Used when the agent chat is hosted in a window pane (Phase F) rather
  than as a full-screen surface. Renders chat messages in the top portion
  and the prompt input at the bottom, without title bar, modeline,
  separator, or file viewer.

  Returns a flat list of draw commands positioned within the given rect.
  """
  @spec render_in_rect(state(), rect()) :: [DisplayList.draw()]
  def render_in_rect(%EditorState{} = state, {row, col, width, height}) do
    input = extract_input(state)

    input_height =
      compute_input_height(input.panel.input_lines, input_inner_width(width))

    chat_height = max(height - input_height, 1)
    input_row = row + chat_height

    {chat_draws, _metrics} =
      render_chat_from_input(input, {row, col, width, chat_height})

    input_draws = render_input_from_input(input, input_row, width)

    chat_draws ++ input_draws
  end

  @doc """
  Returns `{row, col}` for where the terminal cursor should be placed.

  When the chat input is focused the cursor sits in the full-width input area.
  Otherwise the cursor is hidden off-screen.
  """
  @spec cursor_position(state()) :: {non_neg_integer(), non_neg_integer()}
  def cursor_position(state) do
    rows = state.viewport.rows
    panel = AgentAccess.panel(state)

    if panel.input_focused do
      cols = state.viewport.cols
      chat_width_pct = AgentAccess.agentic(state).chat_width_pct
      chat_width = max(div(cols * chat_width_pct, 100), 20)
      inner_width = input_inner_width(chat_width)

      lines = PanelState.input_lines(panel)
      cursor = PanelState.input_cursor(panel)

      total_visual = InputWrap.visual_line_count(lines, inner_width)
      visible_lines = max(min(total_visual, @max_input_lines), 1)
      input_height = compute_input_height(lines, inner_width)
      modeline_row = rows - 1 - 1
      panel_start = 2
      panel_height = max(modeline_row - panel_start, 1)
      chat_height = max(panel_height - input_height, 1)
      input_row = panel_start + chat_height

      # Map logical cursor to visual position within wrapped lines
      {visual_line, visual_col} =
        InputWrap.logical_to_visual(lines, inner_width, cursor)

      scroll = InputWrap.scroll_offset(visual_line, visible_lines, total_visual)
      visible_offset = visual_line - scroll

      # Text starts at input_row + 1 (after top border), col 4 (after "│" + 3 spaces)
      input_text_row = input_row + 1 + min(visible_offset, visible_lines - 1)
      input_col = 1 + 3 + visual_col
      {input_text_row, input_col}
    else
      {rows, 0}
    end
  end

  # ── Input extraction ────────────────────────────────────────────────────────

  @spec extract_input(state()) :: RenderInput.t()
  defp extract_input(state) do
    agent = AgentAccess.agent(state)
    panel = AgentAccess.panel(state)
    session = AgentAccess.session(state)
    agentic = AgentAccess.agentic(state)

    messages =
      if session do
        try do
          Session.messages(session)
        catch
          :exit, _ -> []
        end
      else
        []
      end

    usage =
      if session do
        try do
          Session.usage(session)
        catch
          :exit, _ -> empty_usage()
        end
      else
        empty_usage()
      end

    # Pre-fetch buffer snapshot for file viewer.
    # When pinned, we ask for the tail of the buffer by passing a large
    # offset; render_snapshot clamps internally.
    preview_scroll =
      if agentic.preview.scroll.pinned do
        # Large value that render_snapshot will clamp to the real bottom.
        999_999
      else
        agentic.preview.scroll.offset
      end

    rows = state.viewport.rows
    cols = state.viewport.cols
    pct = agentic.chat_width_pct
    chat_w = max(div(cols * pct, 100), 20)
    input_h = compute_input_height(PanelState.input_lines(panel), input_inner_width(chat_w))
    content_rows = max(rows - 1 - 1 - input_h - 1 - 1, 1)

    buffer_snapshot =
      case state.buffers.active do
        nil ->
          nil

        buf ->
          snapshot = BufferServer.render_snapshot(buf, preview_scroll, content_rows)
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
        input_lines: PanelState.input_lines(panel),
        input_cursor: PanelState.input_cursor(panel),
        mode: state.mode,
        mode_state: state.mode_state,
        scroll: panel.scroll,
        spinner_frame: panel.spinner_frame,
        model_name: panel.model_name,
        provider_name: panel.provider_name,
        thinking_level: panel.thinking_level,
        display_start_index: panel.display_start_index,
        mention_completion: panel.mention_completion,
        pasted_blocks: panel.pasted_blocks
      },
      agentic: %{
        chat_width_pct: agentic.chat_width_pct,
        help_visible: agentic.help_visible,
        focus: agentic.focus,
        search: agentic.search,
        toast: agentic.toast,
        context_estimate: agentic.context_estimate
      },
      messages: messages,
      usage: usage,
      preview: agentic.preview,
      buffer_snapshot: buffer_snapshot,
      highlight: highlight,
      mode: state.mode,
      mode_state: state.mode_state,
      buf_index: state.buffers.active_index + 1,
      buf_count: length(state.buffers.list),
      pending_approval: agent.pending_approval,
      session_title: session_title(messages),
      lsp_servers: safe_lsp_servers()
    }
  end

  @spec safe_lsp_servers() :: [atom()]
  defp safe_lsp_servers do
    Minga.LSP.Supervisor.active_servers()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @spec session_title([term()]) :: String.t()
  defp session_title(messages) do
    case Enum.find(messages, fn msg -> match?({:user, _}, msg) end) do
      {:user, text} -> truncate_title(text)
      nil -> "Minga Agent"
    end
  end

  @spec truncate_title(String.t()) :: String.t()
  defp truncate_title(text) do
    first_line = text |> String.split("\n") |> hd()
    truncated = String.slice(first_line, 0, 50)
    if String.length(truncated) == 50, do: truncated <> "...", else: truncated
  end

  # ── Title bar ───────────────────────────────────────────────────────────────

  @spec render_title_bar_from_input(RenderInput.t(), non_neg_integer(), pos_integer()) ::
          [DisplayList.draw()]
  defp render_title_bar_from_input(input, row, cols) do
    at = Theme.agent_theme(input.theme)
    panel = input.panel

    status_icon = status_icon(input.agent_status, panel.spinner_frame)
    status_fg = status_fg(input.agent_status, at)

    estimate = input.agentic.context_estimate
    usage_text = format_usage(input.usage)
    context_text = format_context_bar(input.usage, panel.model_name, estimate)

    left = " #{status_icon} "
    center = input.session_title

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
        String.duplicate("─", max(gap_left - 1, 1)) <>
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
      render_context_bar_overlay(
        row,
        cols,
        right_len,
        input.usage,
        panel.model_name,
        at,
        estimate
      )

    cmds ++ context_bar_cmds
  end

  # ── Chat panel (messages only) ──────────────────────────────────────────────

  @spec render_chat_from_input(RenderInput.t(), rect()) ::
          {[DisplayList.draw()], ChatRenderer.scroll_metrics()}
  defp render_chat_from_input(input, rect) do
    panel_state = %{
      messages: input.messages,
      status: input.agent_status || :idle,
      input_lines: input.panel.input_lines,
      scroll: input.panel.scroll,
      spinner_frame: input.panel.spinner_frame,
      usage: input.usage,
      model_name: input.panel.model_name,
      thinking_level: input.panel.thinking_level,
      display_start_index: input.panel.display_start_index,
      error_message: nil,
      pending_approval: input.pending_approval,
      mention_completion: input.panel.mention_completion
    }

    ChatRenderer.render_messages_only(rect, panel_state, input.theme)
  end

  @typedoc "Scroll metrics propagated from the chat renderer for caching in PanelState."
  @type scroll_metrics :: ChatRenderer.scroll_metrics()

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
         %{preview: %Preview{content: {:shell, cmd, output, status}, scroll: scroll}} =
           input,
         rect
       ) do
    spinner = input.panel.spinner_frame

    ShellRenderer.render(
      rect,
      cmd,
      output,
      status,
      scroll.offset,
      scroll.pinned,
      spinner,
      input.theme
    )
  end

  defp render_preview(
         %{preview: %Preview{content: {:file, path, content}, scroll: scroll}} = input,
         {row_off, col_off, width, height}
       ) do
    render_file_preview(
      input,
      path,
      content,
      scroll.offset,
      scroll.pinned,
      {row_off, col_off, width, height}
    )
  end

  defp render_preview(
         %{preview: %Preview{content: {:directory, path, entries}, scroll: scroll}} =
           input,
         rect
       ) do
    DirectoryRenderer.render(
      rect,
      path,
      entries,
      scroll.offset,
      scroll.pinned,
      input.theme
    )
  end

  defp render_preview(%{preview: %Preview{content: :empty}} = input, rect) do
    render_dashboard(input, rect)
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

  # ── Dashboard panel (session info) ──────────────────────────────────────────

  @spec render_dashboard(RenderInput.t(), rect()) :: [DisplayList.draw()]
  defp render_dashboard(input, {row_off, col_off, width, height}) do
    at = Theme.agent_theme(input.theme)
    blank = String.duplicate(" ", width)

    # Background fill
    bg_cmds =
      for row <- 0..(height - 1) do
        DisplayList.draw(row_off + row, col_off, blank, bg: at.panel_bg)
      end

    sections = dashboard_sections(input, width, at)

    # Working directory pinned to bottom 2 rows
    cwd = File.cwd!() |> shorten_path()

    dir_label =
      dashboard_text(" Directory", width, fg: at.dashboard_label, bg: at.panel_bg, bold: true)

    dir_value = dashboard_text("  #{cwd}", width, fg: at.text_fg, bg: at.panel_bg)

    dir_start = row_off + max(height - 2, 0)

    dir_cmds = [
      dir_label.(dir_start, col_off),
      dir_value.(min(dir_start + 1, row_off + height - 1), col_off)
    ]

    # Render sections top-down, stopping before the pinned directory
    section_limit = max(height - 3, 1)

    {section_cmds, _} =
      Enum.reduce(sections, {[], row_off}, fn line, {acc, row} ->
        if row >= row_off + section_limit do
          {acc, row}
        else
          {[line.(row, col_off) | acc], row + 1}
        end
      end)

    bg_cmds ++ Enum.reverse(section_cmds) ++ dir_cmds
  end

  @spec dashboard_sections(RenderInput.t(), pos_integer(), Theme.Agent.t()) :: [
          (non_neg_integer(), non_neg_integer() -> DisplayList.draw())
        ]
  defp dashboard_sections(input, width, at) do
    panel = input.panel
    usage = input.usage

    # ── Session title section ──
    title_lines = [
      dashboard_text(" #{input.session_title}", width,
        fg: at.header_fg,
        bg: at.panel_bg,
        bold: true
      ),
      dashboard_blank(width, at)
    ]

    # ── Context section ──
    total_tokens = Map.get(usage, :input, 0) + Map.get(usage, :output, 0)
    estimate = input.agentic.context_estimate
    display_tokens = max(total_tokens, estimate)
    limit = ModelLimits.context_limit(panel.model_name)

    context_lines = [
      dashboard_text(" Context", width, fg: at.dashboard_label, bg: at.panel_bg, bold: true)
    ]

    context_lines =
      if display_tokens > 0 do
        pct_text =
          if limit,
            do: " (#{context_fill_pct(usage, panel.model_name, estimate) || 0}% used)",
            else: ""

        cost_text = if usage.cost > 0, do: "$#{Float.round(usage.cost, 4)}", else: "$0.00"
        cache_read = Map.get(usage, :cache_read, 0)

        context_lines ++
          [
            dashboard_text("  #{format_tokens(total_tokens)} tokens#{pct_text}", width,
              fg: at.text_fg,
              bg: at.panel_bg
            ),
            dashboard_text(
              "  ↑ #{format_tokens(Map.get(usage, :input, 0))} in  ↓ #{format_tokens(Map.get(usage, :output, 0))} out",
              width,
              fg: at.hint_fg,
              bg: at.panel_bg
            )
          ] ++
          if cache_read > 0 do
            [
              dashboard_text("  cache: #{format_tokens(cache_read)} read", width,
                fg: at.hint_fg,
                bg: at.panel_bg
              )
            ]
          else
            []
          end ++
          [
            dashboard_text("  #{cost_text} spent", width, fg: at.text_fg, bg: at.panel_bg),
            dashboard_blank(width, at)
          ]
      else
        context_lines ++
          [
            dashboard_text("  No usage yet", width, fg: at.hint_fg, bg: at.panel_bg),
            dashboard_blank(width, at)
          ]
      end

    # ── Model section ──
    thinking = if panel.thinking_level != "", do: " (#{panel.thinking_level})", else: ""

    model_lines = [
      dashboard_text(" Model", width, fg: at.dashboard_label, bg: at.panel_bg, bold: true),
      dashboard_text("  #{panel.model_name}#{thinking}", width,
        fg: at.text_fg,
        bg: at.panel_bg
      ),
      dashboard_blank(width, at)
    ]

    # ── LSP section ──
    lsp_lines = dashboard_lsp_section(input.lsp_servers, width, at)

    title_lines ++ context_lines ++ model_lines ++ lsp_lines
  end

  @spec dashboard_lsp_section([atom()], pos_integer(), Theme.Agent.t()) :: [
          (non_neg_integer(), non_neg_integer() -> DisplayList.draw())
        ]
  defp dashboard_lsp_section([], width, at) do
    [
      dashboard_text(" LSP", width, fg: at.dashboard_label, bg: at.panel_bg, bold: true),
      dashboard_text("  No servers active", width, fg: at.hint_fg, bg: at.panel_bg),
      dashboard_blank(width, at)
    ]
  end

  defp dashboard_lsp_section(servers, width, at) do
    header = [
      dashboard_text(" LSP", width, fg: at.dashboard_label, bg: at.panel_bg, bold: true)
    ]

    server_lines =
      Enum.map(servers, fn name ->
        dashboard_text("  #{name}", width, fg: at.text_fg, bg: at.panel_bg)
      end)

    header ++ server_lines ++ [dashboard_blank(width, at)]
  end

  @spec dashboard_text(String.t(), pos_integer(), keyword()) ::
          (non_neg_integer(), non_neg_integer() -> DisplayList.draw())
  defp dashboard_text(text, width, opts) do
    padded = String.slice(text, 0, width) |> String.pad_trailing(width)
    fn row, col -> DisplayList.draw(row, col, padded, opts) end
  end

  @spec dashboard_blank(pos_integer(), Theme.Agent.t()) ::
          (non_neg_integer(), non_neg_integer() -> DisplayList.draw())
  defp dashboard_blank(width, at) do
    blank = String.duplicate(" ", width)
    fn row, col -> DisplayList.draw(row, col, blank, bg: at.panel_bg) end
  end

  @spec shorten_path(String.t()) :: String.t()
  defp shorten_path(path) do
    home = System.user_home() || ""

    if String.starts_with?(path, home) do
      "~" <> String.trim_leading(path, home)
    else
      path
    end
  end

  # ── File content preview ────────────────────────────────────────────────────

  @spec render_file_preview(
          RenderInput.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          boolean(),
          rect()
        ) ::
          [DisplayList.draw()]
  defp render_file_preview(
         input,
         path,
         content,
         scroll,
         auto_follow,
         {row_off, col_off, width, height}
       ) do
    at = Theme.agent_theme(input.theme)
    lines = String.split(content, "\n")
    total = length(lines)

    content_start = row_off + 1
    content_rows = max(height - 1, 1)
    max_scroll = max(total - content_rows, 0)
    scroll_clamped = if auto_follow, do: max_scroll, else: min(scroll, max_scroll)
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

    content_start = row_off + 1
    content_rows = max(height - 1, 1)

    lines = snapshot.lines
    line_count = snapshot.line_count

    scroll = Scroll.resolve(input.preview.scroll, line_count, content_rows)

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

  # ── Input area (left column) ──────────────────────────────────────────────

  @spec render_input_from_input(RenderInput.t(), non_neg_integer(), pos_integer()) ::
          [DisplayList.draw()]
  defp render_input_from_input(input, row, width) do
    at = Theme.agent_theme(input.theme)
    panel = input.panel
    border_style = [fg: at.input_border, bg: at.panel_bg]

    is_empty = panel.input_lines == [""]
    inner_width = input_inner_width(width)
    total_visual = InputWrap.visual_line_count(panel.input_lines, inner_width)
    visible_lines = max(min(total_visual, @max_input_lines), 1)

    # Horizontal layout: "│" (1) + "   " (3) + text + pad + " " (1) + "│" (1) = 6 chars of chrome
    pad_left = 3
    pad_right = 1
    left_pad = String.duplicate(" ", pad_left)
    right_pad = String.duplicate(" ", pad_right)

    # ── Top border: ╭─ Prompt ─────────── NORMAL ─╮
    mode_tag = input_mode_label(panel)
    label = "─ Prompt "
    right_tag = if mode_tag != "", do: " " <> mode_tag <> " ─", else: ""
    fill_len = max(width - 2 - String.length(label) - String.length(right_tag), 0)
    top_line = "╭" <> label <> String.duplicate("─", fill_len) <> right_tag <> "╮"
    top_cmd = DisplayList.draw(row, 0, top_line, border_style)

    # ── Content rows: │   text            │
    content_start = row + 1

    line_cmds =
      if is_empty do
        placeholder = String.slice("Type a message, Enter to send", 0, inner_width)
        padded = String.pad_trailing(placeholder, inner_width)
        inner = left_pad <> padded <> right_pad
        fill = String.pad_trailing(inner, max(width - 2, 0))

        [
          DisplayList.draw(content_start, 0, "│" <> fill <> "│", bg: at.input_bg),
          DisplayList.draw(content_start, 0, "│", border_style),
          DisplayList.draw(content_start, width - 1, "│", border_style),
          DisplayList.draw(content_start, 1 + pad_left, padded,
            fg: at.input_placeholder,
            bg: at.input_bg
          )
        ]
      else
        # Map logical cursor to visual row for scrolling
        {cursor_visual, _} =
          InputWrap.logical_to_visual(panel.input_lines, inner_width, panel.input_cursor)

        scroll = InputWrap.scroll_offset(cursor_visual, visible_lines, total_visual)

        # Build flat list of visual lines tagged with logical line index
        visual_lines = InputWrap.wrap_lines(panel.input_lines, inner_width)

        sel_range = vim_visual_range(panel)

        chrome = %{
          inner_width: inner_width,
          width: width,
          left_pad: left_pad,
          right_pad: right_pad,
          pad_left: pad_left,
          border_style: border_style,
          input_bg: at.input_bg
        }

        visual_lines
        |> Enum.drop(scroll)
        |> Enum.take(visible_lines)
        |> Enum.with_index()
        |> Enum.flat_map(fn {{logical_idx, vl}, idx} ->
          r = content_start + idx
          line_text = Enum.at(panel.input_lines, logical_idx)

          {display_text, fg_color} =
            visual_row_display(vl, line_text, inner_width, panel, at)

          render_input_row(r, display_text, fg_color, chrome, logical_idx, vl, sel_range)
        end)
      end

    # ── Bottom border with model info: ╰─ 󰚩 model · provider ───╯
    bottom_row = content_start + max(visible_lines, 1)
    model_label = model_info_text(input)
    model_prefix = "─ " <> model_label <> " "
    model_fill_len = max(width - 2 - String.length(model_prefix), 0)
    bottom_line = "╰" <> model_prefix <> String.duplicate("─", model_fill_len) <> "╯"
    bottom_cmd = DisplayList.draw(bottom_row, 0, bottom_line, border_style)

    [top_cmd | line_cmds] ++ [bottom_cmd]
  end

  @spec model_info_text(RenderInput.t()) :: String.t()
  defp model_info_text(input) do
    panel = input.panel
    model = titleize(panel.model_name)
    provider = if panel.provider_name != "", do: " · #{titleize(panel.provider_name)}", else: ""
    thinking = if panel.thinking_level != "", do: " · #{panel.thinking_level}", else: ""
    "󰚩 #{model}#{provider}#{thinking}"
  end

  @spec titleize(String.t()) :: String.t()
  defp titleize(str) do
    str
    |> String.split(~r/[-_\s]+/)
    |> Enum.map_join(" ", fn word ->
      {first, rest} = String.split_at(word, 1)
      String.upcase(first) <> rest
    end)
  end

  # Returns display text and color for a single visual row within a wrapped input.
  # Paste placeholder lines show a compact indicator on their first visual row only.
  # All other visual rows show their wrapped text segment.
  @spec visual_row_display(
          InputWrap.visual_line(),
          String.t(),
          pos_integer(),
          RenderInput.panel_data(),
          Theme.Agent.t()
        ) :: {String.t(), Theme.color()}
  defp visual_row_display(vl, line_text, inner_width, panel, at) do
    if PanelState.paste_placeholder?(line_text) and vl.col_offset == 0 do
      input_line_display(line_text, inner_width, panel, at)
    else
      {vl.text, at.text_fg}
    end
  end

  # Renders a single content row inside the input box with borders, padding,
  # and optional visual selection highlighting.
  @spec render_input_row(
          non_neg_integer(),
          String.t(),
          Theme.color(),
          map(),
          non_neg_integer(),
          InputWrap.visual_line(),
          {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}} | nil
        ) :: [DisplayList.draw()]
  defp render_input_row(row, display_text, fg_color, chrome, logical_idx, vl, sel_range) do
    padded = String.pad_trailing(display_text, chrome.inner_width)
    inner = chrome.left_pad <> padded <> chrome.right_pad
    fill = String.pad_trailing(inner, max(chrome.width - 2, 0))
    text_col = 1 + chrome.pad_left

    base = [
      DisplayList.draw(row, 0, "│" <> fill <> "│", bg: chrome.input_bg),
      DisplayList.draw(row, 0, "│", chrome.border_style),
      DisplayList.draw(row, chrome.width - 1, "│", chrome.border_style),
      DisplayList.draw(row, text_col, padded, fg: fg_color, bg: chrome.input_bg)
    ]

    case selection_slice(logical_idx, vl.col_offset, String.length(display_text), sel_range) do
      nil ->
        base

      {sel_start, sel_len} ->
        sel_text =
          display_text
          |> String.slice(sel_start, sel_len)
          |> String.pad_trailing(sel_len)

        base ++
          [
            DisplayList.draw(row, text_col + sel_start, sel_text,
              fg: fg_color,
              bg: chrome.input_bg,
              reverse: true
            )
          ]
    end
  end

  # Returns {start_col, length} of the selected portion within a visual line,
  # or nil if no overlap. All coordinates are grapheme-based.
  @spec selection_slice(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}} | nil
        ) :: {non_neg_integer(), pos_integer()} | nil
  defp selection_slice(_logical_idx, _col_offset, _text_len, nil), do: nil

  defp selection_slice(logical_idx, _col_offset, _text_len, {{from_line, _}, {to_line, _}})
       when logical_idx < from_line or logical_idx > to_line,
       do: nil

  defp selection_slice(
         logical_idx,
         col_offset,
         text_len,
         {{from_line, from_col}, {to_line, to_col}}
       ) do
    sel_start = if logical_idx == from_line, do: from_col, else: 0
    sel_end = if logical_idx == to_line, do: to_col + 1, else: col_offset + text_len

    # Clip to this visual line's column range
    vis_start = max(sel_start - col_offset, 0)
    vis_end = min(sel_end - col_offset, text_len)

    if vis_end > vis_start, do: {vis_start, vis_end - vis_start}, else: nil
  end

  # Returns the display text and foreground color for a paste placeholder line.
  @spec input_line_display(String.t(), pos_integer(), RenderInput.panel_data(), Theme.Agent.t()) ::
          {String.t(), Theme.color()}
  defp input_line_display(line_text, inner_width, panel, at) do
    case PanelState.paste_block_index(line_text) do
      nil ->
        {String.slice(line_text, 0, inner_width), at.text_fg}

      block_index ->
        line_count = paste_block_line_count(panel.pasted_blocks, block_index)
        indicator = "󰆏 [pasted #{line_count} lines]"
        {String.slice(indicator, 0, inner_width), at.hint_fg}
    end
  end

  # Count lines in a paste block by index. Returns 0 if the index is invalid.
  @spec paste_block_line_count([PanelState.paste_block()], non_neg_integer()) ::
          non_neg_integer()
  defp paste_block_line_count(blocks, index) do
    case Enum.at(blocks, index) do
      %{text: text} -> text |> String.split("\n") |> length()
      nil -> 0
    end
  end

  # Computes the text width inside the input box, excluding borders and padding.
  # Layout: "│" (1) + padding_left (3) + text + padding_right (1) + "│" (1) = 6 chars chrome.
  @spec input_inner_width(pos_integer()) :: pos_integer()
  defp input_inner_width(box_width), do: max(box_width - 6, 1)

  # Returns the visual selection range from Vim state, or nil.
  @spec vim_visual_range(map()) ::
          {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}} | nil
  # Visual selection range for the prompt input. Uses the editor's mode
  # state (visual_start) when in visual mode, since the prompt uses the
  # standard Mode FSM.
  @spec vim_visual_range(map()) ::
          {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}} | nil
  defp vim_visual_range(%{input_cursor: cursor, mode: mode, mode_state: mode_state})
       when mode in [:visual, :visual_line] do
    case mode_state do
      %{visual_start: {vl, vc}} when is_integer(vl) ->
        {from, to} = if {vl, vc} <= cursor, do: {{vl, vc}, cursor}, else: {cursor, {vl, vc}}

        if mode == :visual_line do
          {from_line, _} = from
          {to_line, _} = to
          {{from_line, 0}, {to_line, 999_999}}
        else
          {from, to}
        end

      _ ->
        nil
    end
  end

  defp vim_visual_range(_panel), do: nil

  # Returns a mode label for the prompt border.
  @spec input_mode_label(map()) :: String.t()
  defp input_mode_label(%{mode: :insert}), do: ""
  defp input_mode_label(%{mode: :normal}), do: "NORMAL"
  defp input_mode_label(%{mode: :visual}), do: "VISUAL"
  defp input_mode_label(%{mode: :visual_line}), do: "V-LINE"
  defp input_mode_label(%{mode: :operator_pending}), do: "OP"
  defp input_mode_label(_panel), do: ""

  # Computes the dynamic input area height for the bordered box:
  # top border(1) + visible lines + bottom border(1).
  # Uses visual line count (accounting for soft-wrap at inner_width).
  @spec compute_input_height([String.t()], pos_integer()) :: pos_integer()
  defp compute_input_height(input_lines, inner_width) do
    visible = InputWrap.visible_height(input_lines, inner_width, @max_input_lines)
    visible + 2
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
    {draws, _click_regions} =
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

    at = Theme.agent_theme(input.theme)

    hints =
      case input.agentic.focus do
        :chat ->
          if input.panel.input_focused do
            "C-c C-c send  Esc cancel  C-c abort"
          else
            "i input  ? help  / search  q quit"
          end

        :file_viewer ->
          "Tab focus  j/k scroll  ? help  q quit"
      end

    version_text = " • Minga #{Minga.version()} "
    hint_text = " #{hints} "
    right_text = hint_text <> version_text
    right_col = max(cols - String.length(right_text), 0)

    hint_cmd =
      DisplayList.draw(row, right_col, hint_text,
        fg: at.hint_fg,
        bg: input.theme.modeline.bar_bg
      )

    version_cmd =
      DisplayList.draw(row, right_col + String.length(hint_text), version_text,
        fg: at.hint_fg,
        bg: input.theme.modeline.bar_bg
      )

    # Idle dots animation: subtle braille spinner when agent is idle
    idle_cmds =
      case input.agent_status do
        status when status in [:idle, nil] ->
          frames = ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
          frame = Enum.at(frames, rem(input.panel.spinner_frame, length(frames)))

          [
            DisplayList.draw(row, right_col - 3, " #{frame} ",
              fg: at.hint_fg,
              bg: input.theme.modeline.bar_bg
            )
          ]

        _active ->
          []
      end

    draws ++ idle_cmds ++ [hint_cmd, version_cmd]
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
  @spec context_fill_pct(map(), String.t(), non_neg_integer()) :: non_neg_integer() | nil
  def context_fill_pct(usage, model_name, context_estimate \\ 0) do
    limit = ModelLimits.context_limit(model_name)

    case limit do
      nil ->
        nil

      0 ->
        nil

      n ->
        actual = Map.get(usage, :input, 0) + Map.get(usage, :output, 0)
        # Use the higher of actual usage or pre-send estimate
        used = max(actual, context_estimate)
        min(round(used / n * 100), 100)
    end
  end

  # Formats the context bar as plain text for title bar layout measurement.
  @spec format_context_bar(map(), String.t(), non_neg_integer()) :: String.t()
  defp format_context_bar(usage, model_name, context_estimate) do
    case context_fill_pct(usage, model_name, context_estimate) do
      nil -> ""
      pct -> context_bar_text(pct)
    end
  end

  @spec context_bar_text(non_neg_integer()) :: String.t()
  defp context_bar_text(pct) do
    filled = div(pct * @context_bar_width, 100)
    empty = @context_bar_width - filled
    "Context [#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}] #{pct}%"
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
          Theme.Agent.t(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp render_context_bar_overlay(row, cols, right_len, usage, model_name, at, context_estimate) do
    case context_fill_pct(usage, model_name, context_estimate) do
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

    groups = Scope.help_groups(:agent, input.agentic.focus)

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

  @spec help_content_lines([Scope.help_group()]) :: [help_line()]
  defp help_content_lines(groups) do
    Enum.flat_map(groups, fn {category, bindings} ->
      header = [{:header, category, ""}]
      items = Enum.map(bindings, fn {key, desc} -> {:binding, key, desc} end)
      header ++ items ++ [{:spacer, "", ""}]
    end)
  end
end
