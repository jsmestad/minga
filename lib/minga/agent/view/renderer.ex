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

  Called by `Minga.Editor.Renderer` when `state.agentic.active` is true.
  """

  alias Minga.Agent.ChatRenderer
  alias Minga.Agent.Session
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Modeline
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.Line, as: LineRenderer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Port.Protocol
  alias Minga.Theme

  @typedoc "Screen rectangle {row_offset, col_offset, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @input_height 3

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Renders the full-screen agentic view and returns a flat list of draw commands.

  The caller (Renderer.render_agentic/1) prepends a clear command and appends
  the cursor, cursor-shape, and batch-end commands before sending.
  """
  @spec render(state()) :: [binary()]
  def render(state) do
    cols = state.viewport.cols
    rows = state.viewport.rows

    # Layout math:
    #   Row 0         = title bar
    #   Row 1..P-1    = panels (chat + viewer)
    #   Row P..P+2    = input area (3 rows)
    #   Row P+3       = modeline
    #   Row P+4       = minibuffer (reserved; rows - 1)
    #
    # P = rows - 1 (minibuffer) - 1 (modeline) - @input_height
    panel_end = rows - 1 - 1 - @input_height
    panel_start = 1
    panel_height = max(panel_end - panel_start, 1)

    chat_width_pct = state.agentic.chat_width_pct
    chat_width = max(div(cols * chat_width_pct, 100), 20)
    separator_col = chat_width
    viewer_col = chat_width + 1
    viewer_width = max(cols - viewer_col, 10)

    input_row = panel_end
    modeline_row = input_row + @input_height

    title_commands = render_title_bar(state, 0, cols)
    chat_commands = render_chat(state, {panel_start, 0, chat_width, panel_height})
    separator_commands = render_separator(separator_col, panel_start, panel_height, state.theme)

    viewer_commands =
      render_file_viewer(state, {panel_start, viewer_col, viewer_width, panel_height})

    input_commands = render_input(state, input_row, cols)
    modeline_commands = render_modeline(state, modeline_row, cols)

    title_commands ++
      chat_commands ++
      separator_commands ++
      viewer_commands ++
      input_commands ++
      modeline_commands
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
      # Input text row = panel_end + 1 (border is panel_end, text is +1)
      panel_end = rows - 1 - 1 - @input_height
      input_text_row = panel_end + 1
      input_col = 2 + String.length(state.agent.panel.input_text)
      {input_text_row, input_col}
    else
      {rows, 0}
    end
  end

  # ── Title bar ───────────────────────────────────────────────────────────────

  @spec render_title_bar(state(), non_neg_integer(), pos_integer()) :: [binary()]
  defp render_title_bar(state, row, cols) do
    at = Theme.agent_theme(state.theme)
    panel = state.agent.panel

    status_icon =
      case state.agent.status do
        :idle -> "◯"
        :thinking -> spinner(panel.spinner_frame)
        :tool_executing -> "⚡"
        :error -> "✗"
        _ -> "◯"
      end

    status_fg =
      case state.agent.status do
        :idle -> at.status_idle
        :thinking -> at.status_thinking
        :tool_executing -> at.status_tool
        :error -> at.status_error
        _ -> at.status_idle
      end

    usage = fetch_usage(state)
    usage_text = format_usage(usage)

    left = " #{status_icon}  󰚩 #{panel.model_name}"
    center = "Minga Agent"
    right = if usage_text != "", do: "#{usage_text} ", else: ""

    # Build the title bar with left/center/right alignment
    left_len = String.length(left)
    center_len = String.length(center)
    right_len = String.length(right)

    # Center the title text
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

    # Trim or pad to exact width
    bar_text = String.slice(bar_text, 0, cols) |> String.pad_trailing(cols)

    [
      Protocol.encode_draw(row, 0, bar_text, fg: at.panel_border, bg: at.header_bg),
      # Re-draw the status icon with its color
      Protocol.encode_draw(row, 1, status_icon, fg: status_fg, bg: at.header_bg, bold: true),
      # Re-draw the center title with emphasis
      Protocol.encode_draw(row, center_start, center,
        fg: at.header_fg,
        bg: at.header_bg,
        bold: true
      )
    ]
  end

  # ── Chat panel (messages only) ──────────────────────────────────────────────

  @spec render_chat(state(), rect()) :: [binary()]
  defp render_chat(state, rect) do
    agent = state.agent

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

    usage = fetch_usage(state)

    panel_state = %{
      messages: messages,
      status: agent.status || :idle,
      input_text: agent.panel.input_text,
      scroll_offset: agent.panel.scroll_offset,
      spinner_frame: agent.panel.spinner_frame,
      usage: usage,
      model_name: agent.panel.model_name,
      thinking_level: agent.panel.thinking_level,
      error_message: agent.error
    }

    ChatRenderer.render_messages_only(rect, panel_state, state.theme)
  end

  # ── Vertical separator ──────────────────────────────────────────────────────

  @spec render_separator(non_neg_integer(), non_neg_integer(), pos_integer(), Theme.t()) ::
          [binary()]
  defp render_separator(col, start_row, height, theme) do
    at = Theme.agent_theme(theme)

    for row <- start_row..(start_row + height - 1) do
      Protocol.encode_draw(row, col, "│", fg: at.panel_border, bg: at.panel_bg)
    end
  end

  # ── File viewer panel ───────────────────────────────────────────────────────

  @spec render_file_viewer(state(), rect()) :: [binary()]
  defp render_file_viewer(%{buffers: %{active: nil}}, {row_off, col_off, width, height}) do
    blank = String.duplicate(" ", width)

    for row <- 0..(height - 1) do
      Protocol.encode_draw(row_off + row, col_off, blank)
    end
  end

  defp render_file_viewer(state, {row_off, col_off, width, height}) do
    buf = state.buffers.active
    scroll = state.agentic.file_viewer_scroll

    # First row = filename header, remaining rows = file content
    content_start = row_off + 1
    content_rows = max(height - 1, 1)

    snapshot = BufferServer.render_snapshot(buf, scroll, content_rows)
    lines = snapshot.lines
    line_count = snapshot.line_count

    abs_gutter_col = max(col_off, 0)
    local_gutter_w = file_viewer_gutter_width(line_count)
    abs_content_col = col_off + local_gutter_w
    content_w = max(width - local_gutter_w, 1)

    viewer_vp = Viewport.new(content_rows, width)
    viewer_vp = %{viewer_vp | top: scroll}

    highlight =
      if state.highlight.current.capture_names != [], do: state.highlight.current, else: nil

    render_ctx = %Context{
      viewport: viewer_vp,
      visual_selection: nil,
      search_matches: [],
      gutter_w: abs_content_col,
      content_w: content_w,
      confirm_match: nil,
      highlight: highlight,
      has_sign_column: false,
      diagnostic_signs: %{},
      git_signs: %{},
      search_colors: state.theme.search,
      gutter_colors: state.theme.gutter,
      git_colors: state.theme.git
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
          Protocol.encode_draw(r, abs_content_col, "~", fg: state.theme.editor.tilde_fg)
        end
      else
        []
      end

    # File name header bar at the TOP of the viewer panel
    at = Theme.agent_theme(state.theme)
    file_name = snapshot_display_name(snapshot)
    header_text = String.pad_trailing(" 📄 #{file_name}", width)

    header_cmd =
      Protocol.encode_draw(row_off, col_off, header_text, fg: at.header_fg, bg: at.header_bg)

    [header_cmd | gutter_cmds] ++ line_cmds ++ tilde_cmds
  end

  # ── Full-width input area ───────────────────────────────────────────────────

  @spec render_input(state(), non_neg_integer(), pos_integer()) :: [binary()]
  defp render_input(state, row, cols) do
    at = Theme.agent_theme(state.theme)
    panel = state.agent.panel

    # Border line (full width)
    label = "─── Prompt "
    border_rest = String.duplicate("─", max(cols - String.length(label), 0))
    border = label <> border_rest
    border_cmd = Protocol.encode_draw(row, 0, border, fg: at.input_border, bg: at.panel_bg)

    # Input text row (full width)
    input_row = row + 1
    blank = String.duplicate(" ", cols)
    blank_cmd = Protocol.encode_draw(input_row, 0, blank, bg: at.input_bg)

    {text, fg} =
      if panel.input_text == "" do
        {"  Type a message, Enter to send", at.input_placeholder}
      else
        {"  " <> panel.input_text, at.text_fg}
      end

    text = String.slice(text, 0, cols)
    text_cmd = Protocol.encode_draw(input_row, 0, text, fg: fg, bg: at.input_bg)

    # Bottom padding row
    pad_cmd = Protocol.encode_draw(row + 2, 0, blank, bg: at.input_bg)

    [border_cmd, blank_cmd, text_cmd, pad_cmd]
  end

  # ── Modeline ────────────────────────────────────────────────────────────────

  @spec render_modeline(state(), non_neg_integer(), pos_integer()) :: [binary()]
  defp render_modeline(state, row, cols) do
    Modeline.render(
      row,
      cols,
      %{
        mode: state.mode,
        mode_state: state.mode_state,
        mode_override: "AGENT",
        file_name: "AGENT",
        filetype: :text,
        dirty_marker: "",
        cursor_line: 0,
        cursor_col: 0,
        line_count: 0,
        buf_index: state.buffers.active_index + 1,
        buf_count: length(state.buffers.list),
        macro_recording: false,
        agent_status: state.agent.status,
        agent_theme_colors: Theme.agent_theme(state.theme)
      },
      state.theme
    )
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec file_viewer_gutter_width(non_neg_integer()) :: non_neg_integer()
  defp file_viewer_gutter_width(line_count) do
    digits = line_count |> max(1) |> Integer.digits() |> length()
    digits + 1
  end

  @spec snapshot_display_name(map()) :: String.t()
  defp snapshot_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp snapshot_display_name(_), do: "[No Name]"

  @spec fetch_usage(state()) :: map()
  defp fetch_usage(state) do
    if state.agent.session do
      try do
        Session.usage(state.agent.session)
      catch
        :exit, _ -> empty_usage()
      end
    else
      empty_usage()
    end
  end

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

  @spec spinner(non_neg_integer()) :: String.t()
  defp spinner(frame) do
    chars = ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    Enum.at(chars, rem(frame, length(chars)))
  end
end
