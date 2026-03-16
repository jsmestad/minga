defmodule Minga.Agent.View.Renderer do
  @moduledoc """
  Agent view rendering helpers: prompt input, dashboard sidebar, and cursor positioning.

  Chat content rendering is handled by the standard buffer pipeline through
  the `*Agent*` buffer (managed by `BufferSync` and decorated by `ChatDecorations`).
  This module provides only the supplementary chrome:

  - **Prompt input box** (`render_prompt_only/2`) with vim mode indicator
  - **Dashboard sidebar** (`render_dashboard_only/2`) showing context, model, LSP status
  - **Cursor positioning** (`cursor_position_in_rect/2`) for the input area
  - **Prompt height** (`prompt_height/2`) for layout computation

  Called by `Minga.Editor.RenderPipeline.Content` when rendering agent chat windows.
  """

  alias Minga.Agent.Config, as: AgentConfig
  alias Minga.Agent.ModelLimits
  alias Minga.Agent.Session
  alias Minga.Agent.UIState
  alias Minga.Editor.DisplayList
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess

  alias Minga.Input.Wrap, as: InputWrap
  alias Minga.Scroll
  alias Minga.Theme

  @typedoc "Screen rectangle {row_offset, col_offset, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @max_input_lines 8
  @input_h_margin 2
  @input_v_gap 1

  # ── Focused input type ─────────────────────────────────────────────────────

  defmodule RenderInput do
    @moduledoc """
    Focused input for the agentic view renderer.

    Contains exactly the data needed to render the full-screen agent view,
    without requiring a full `EditorState`. This enables isolated testing
    and makes the data dependency graph explicit.
    """

    alias Minga.Theme

    @enforce_keys [:theme, :agent_status, :panel, :agent_ui]
    defstruct [
      :theme,
      :agent_status,
      :panel,
      :agent_ui,
      messages: [],
      usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0},
      pending_approval: nil,
      session_title: "Minga Agent",
      lsp_servers: []
    ]

    @type t :: %__MODULE__{
            theme: Theme.t(),
            agent_status: atom() | nil,
            panel: panel_data(),
            agent_ui: agent_ui_data(),
            messages: list(),
            usage: map(),
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
            pasted_blocks: [UIState.paste_block()]
          }

    @typedoc "Agentic view fields needed for rendering."
    @type agent_ui_data :: %{
            chat_width_pct: non_neg_integer(),
            help_visible: boolean(),
            focus: atom(),
            search: UIState.search_state() | nil,
            toast: UIState.toast() | nil,
            context_estimate: non_neg_integer()
          }
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Computes the input prompt height for a given chat width.

  Used by Content stage to determine how much space to reserve for
  the prompt at the bottom of the agent chat window.
  """
  @spec prompt_height(state(), pos_integer()) :: pos_integer()
  def prompt_height(%EditorState{} = state, chat_width) do
    input = extract_input(state)
    box_width = max(chat_width - 2 * @input_h_margin, 10)
    compute_input_height(input.panel.input_lines, input_inner_width(box_width))
  end

  @doc """
  Renders only the prompt input area into the given rect.

  Used by the Content stage when the chat content is rendered through
  the standard buffer pipeline with decorations.
  """
  @spec render_prompt_only(state(), rect()) :: [DisplayList.draw()]
  def render_prompt_only(%EditorState{} = state, {row, col, width, _height}) do
    input = extract_input(state)
    box_width = max(width - 2 * @input_h_margin, 10)
    box_col = col + @input_h_margin
    render_input_from_input(input, row, box_col, box_width)
  end

  @doc "Renders the agent dashboard sidebar (Context, Model, LSP, Directory)."
  @spec render_dashboard_only(EditorState.t(), rect()) :: [DisplayList.draw()]
  def render_dashboard_only(%EditorState{} = state, rect) do
    input = extract_input(state)
    render_dashboard(input, rect)
  end

  @doc """
  Returns `{row, col}` for the cursor within a bounded content rect.

  Used by the render pipeline to position the cursor in the agent chat
  input area when the agent is hosted in a window pane. The rect
  determines the coordinate space.

  Returns nil when input is not focused (cursor hidden).
  """
  @spec cursor_position_in_rect(state(), rect()) :: {non_neg_integer(), non_neg_integer()} | nil
  def cursor_position_in_rect(state, {row_off, col_off, width, height}) do
    panel = AgentAccess.panel(state)

    if panel.input_focused do
      agent_ui = AgentAccess.agent_ui(state)
      chat_width_pct = agent_ui.chat_width_pct
      chat_width = max(div(width * chat_width_pct, 100), 20)
      box_width = max(chat_width - 2 * @input_h_margin, 10)
      box_col = col_off + @input_h_margin
      inner_width = input_inner_width(box_width)

      lines = UIState.input_lines(panel)
      cursor = UIState.input_cursor(panel)

      total_visual = InputWrap.visual_line_count(lines, inner_width)
      visible_lines = max(min(total_visual, @max_input_lines), 1)
      input_height = compute_input_height(lines, inner_width)
      chat_height = max(height - input_height - @input_v_gap, 1)
      input_row = row_off + chat_height + @input_v_gap

      {visual_line, visual_col} =
        InputWrap.logical_to_visual(lines, inner_width, cursor)

      scroll = InputWrap.scroll_offset(visual_line, visible_lines, total_visual)
      visible_offset = visual_line - scroll

      input_text_row = input_row + 1 + min(visible_offset, visible_lines - 1)
      input_col = box_col + 1 + 3 + visual_col
      {input_text_row, input_col}
    else
      nil
    end
  end

  # ── Input extraction ────────────────────────────────────────────────────────

  @spec extract_input(state()) :: RenderInput.t()
  defp extract_input(state) do
    agent = AgentAccess.agent(state)
    panel = AgentAccess.panel(state)
    session = AgentAccess.session(state)
    agent_ui = AgentAccess.agent_ui(state)

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

    %RenderInput{
      theme: state.theme,
      agent_status: agent.status,
      panel: %{
        input_focused: panel.input_focused,
        input_lines: UIState.input_lines(panel),
        input_cursor: UIState.input_cursor(panel),
        mode: state.vim.mode,
        mode_state: state.vim.mode_state,
        scroll: panel.scroll,
        spinner_frame: panel.spinner_frame,
        model_name: panel.model_name,
        provider_name: panel.provider_name,
        thinking_level: panel.thinking_level,
        display_start_index: panel.display_start_index,
        mention_completion: panel.mention_completion,
        pasted_blocks: panel.pasted_blocks
      },
      agent_ui: %{
        chat_width_pct: agent_ui.chat_width_pct,
        help_visible: agent_ui.help_visible,
        focus: agent_ui.focus,
        search: agent_ui.search,
        toast: agent_ui.toast,
        context_estimate: agent_ui.context_estimate
      },
      messages: messages,
      usage: usage,
      pending_approval: agent.pending_approval,
      session_title: session_title(messages),
      lsp_servers: safe_lsp_servers()
    }
  end

  @spec safe_lsp_servers() :: [atom()]
  defp safe_lsp_servers do
    Minga.LSP.Supervisor.active_servers()
  catch
    :exit, _ -> []
  end

  @spec session_title([term()]) :: String.t()
  defp session_title(messages) do
    case Enum.find(messages, fn msg -> match?({:user, _}, msg) or match?({:user, _, _}, msg) end) do
      {:user, text} -> truncate_title(text)
      {:user, text, _attachments} -> truncate_title(text)
      nil -> "Minga Agent"
    end
  end

  @spec truncate_title(String.t()) :: String.t()
  defp truncate_title(text) do
    first_line = text |> String.split("\n") |> hd()
    truncated = String.slice(first_line, 0, 50)
    if String.length(truncated) == 50, do: truncated <> "...", else: truncated
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
    bare_model = AgentConfig.strip_provider_prefix(panel.model_name)

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
    estimate = input.agent_ui.context_estimate
    display_tokens = max(total_tokens, estimate)
    limit = ModelLimits.context_limit(bare_model)

    context_lines = [
      dashboard_text(" Context", width, fg: at.dashboard_label, bg: at.panel_bg, bold: true)
    ]

    context_lines =
      if display_tokens > 0 do
        pct_text =
          if limit,
            do: " (#{context_fill_pct(usage, bare_model, estimate) || 0}% used)",
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
      dashboard_text("  #{bare_model}#{thinking}", width,
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

  # ── Input area (left column) ──────────────────────────────────────────────

  @spec render_input_from_input(
          RenderInput.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) ::
          [DisplayList.draw()]
  defp render_input_from_input(input, row, col_off, width) do
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
    top_cmd = DisplayList.draw(row, col_off, top_line, border_style)

    # ── Content rows: │   text            │
    content_start = row + 1

    line_cmds =
      if is_empty do
        placeholder = String.slice("Type a message, Enter to send", 0, inner_width)
        padded = String.pad_trailing(placeholder, inner_width)
        inner = left_pad <> padded <> right_pad
        fill = String.pad_trailing(inner, max(width - 2, 0))

        [
          DisplayList.draw(content_start, col_off, "│" <> fill <> "│", bg: at.input_bg),
          DisplayList.draw(content_start, col_off, "│", border_style),
          DisplayList.draw(content_start, col_off + width - 1, "│", border_style),
          DisplayList.draw(content_start, col_off + 1 + pad_left, padded,
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
          col_off: col_off,
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
    bottom_cmd = DisplayList.draw(bottom_row, col_off, bottom_line, border_style)

    [top_cmd | line_cmds] ++ [bottom_cmd]
  end

  @spec model_info_text(RenderInput.t()) :: String.t()
  defp model_info_text(input) do
    panel = input.panel
    model = panel.model_name |> AgentConfig.strip_provider_prefix() |> titleize()
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
    if UIState.paste_placeholder?(line_text) and vl.col_offset == 0 do
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
    c = Map.get(chrome, :col_off, 0)
    padded = String.pad_trailing(display_text, chrome.inner_width)
    inner = chrome.left_pad <> padded <> chrome.right_pad
    fill = String.pad_trailing(inner, max(chrome.width - 2, 0))
    text_col = c + 1 + chrome.pad_left

    base = [
      DisplayList.draw(row, c, "│" <> fill <> "│", bg: chrome.input_bg),
      DisplayList.draw(row, c, "│", chrome.border_style),
      DisplayList.draw(row, c + chrome.width - 1, "│", chrome.border_style),
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
    case UIState.paste_block_index(line_text) do
      nil ->
        {String.slice(line_text, 0, inner_width), at.text_fg}

      block_index ->
        line_count = paste_block_line_count(panel.pasted_blocks, block_index)
        indicator = "󰆏 [pasted #{line_count} lines]"
        {String.slice(indicator, 0, inner_width), at.hint_fg}
    end
  end

  # Count lines in a paste block by index. Returns 0 if the index is invalid.
  @spec paste_block_line_count([UIState.paste_block()], non_neg_integer()) ::
          non_neg_integer()
  defp paste_block_line_count(blocks, index) do
    case Enum.at(blocks, index) do
      %{text: text} -> text |> String.split("\n") |> length()
      nil -> 0
    end
  end

  @doc """
  Computes the text width inside the input box, excluding borders and padding.

  Layout: "│" (1) + padding_left (3) + text + padding_right (1) + "│" (1) = 6 chars chrome.
  Public so that `Input.AgentMouse` can use the same layout math for hit-testing.
  """
  @spec input_inner_width(pos_integer()) :: pos_integer()
  def input_inner_width(box_width), do: max(box_width - 6, 1)

  @doc """
  Returns the prompt box width after applying horizontal margins.

  The box is inset by `@input_h_margin` on each side of the chat column.
  Public so that `Input.AgentMouse` can use the same layout math for hit-testing.
  """
  @spec input_box_width(pos_integer()) :: pos_integer()
  def input_box_width(chat_width), do: max(chat_width - 2 * @input_h_margin, 10)

  @doc """
  Returns the vertical gap (in rows) between the prompt box and the modeline.

  Public so that `Input.AgentMouse` can use the same layout math for hit-testing.
  """
  @spec input_v_gap() :: non_neg_integer()
  def input_v_gap, do: @input_v_gap

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

  @doc """
  Computes the dynamic input area height for the bordered box:
  top border(1) + visible lines + bottom border(1).

  Uses visual line count (accounting for soft-wrap at inner_width).
  Public so that `Input.AgentMouse` can use the same layout math for hit-testing.
  """
  @spec compute_input_height([String.t()], pos_integer()) :: pos_integer()
  def compute_input_height(input_lines, inner_width) do
    visible = InputWrap.visible_height(input_lines, inner_width, @max_input_lines)
    visible + 2
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec empty_usage() :: map()
  defp empty_usage, do: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}

  @spec format_tokens(non_neg_integer()) :: String.t()
  defp format_tokens(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_tokens(n), do: "#{n}"

  # ── Context bar ─────────────────────────────────────────────────────────────

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
end
