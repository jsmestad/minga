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
  alias Minga.Agent.Session
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

  @input_height 3

  # ── Focused input type ─────────────────────────────────────────────────────

  defmodule RenderInput do
    @moduledoc """
    Focused input for the agentic view renderer.

    Contains exactly the data needed to render the full-screen agent view,
    without requiring a full `EditorState`. This enables isolated testing
    and makes the data dependency graph explicit.
    """

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
      buffer_snapshot: nil,
      highlight: nil,
      mode: :normal,
      mode_state: nil,
      buf_index: 1,
      buf_count: 1
    ]

    @type t :: %__MODULE__{
            viewport: Viewport.t(),
            theme: Theme.t(),
            agent_status: atom() | nil,
            panel: panel_data(),
            agentic: agentic_data(),
            messages: list(),
            usage: map(),
            buffer_snapshot: map() | nil,
            highlight: Highlight.t() | nil,
            mode: atom(),
            mode_state: term(),
            buf_index: pos_integer(),
            buf_count: pos_integer()
          }

    @typedoc "Agent panel fields needed for rendering."
    @type panel_data :: %{
            input_focused: boolean(),
            input_text: String.t(),
            scroll_offset: non_neg_integer(),
            spinner_frame: non_neg_integer(),
            model_name: String.t(),
            thinking_level: String.t()
          }

    @typedoc "Agentic view fields needed for rendering."
    @type agentic_data :: %{
            chat_width_pct: non_neg_integer(),
            file_viewer_scroll: non_neg_integer()
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

    panel_end = rows - 1 - 1 - @input_height
    panel_start = 1
    panel_height = max(panel_end - panel_start, 1)

    chat_width_pct = input.agentic.chat_width_pct
    chat_width = max(div(cols * chat_width_pct, 100), 20)
    separator_col = chat_width
    viewer_col = chat_width + 1
    viewer_width = max(cols - viewer_col, 10)

    input_row = panel_end
    modeline_row = input_row + @input_height

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

    title_commands ++
      chat_commands ++
      separator_commands ++
      viewer_commands ++
      input_commands ++
      modeline_commands
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
      panel_end = rows - 1 - 1 - @input_height
      input_text_row = panel_end + 1
      input_col = 2 + String.length(state.agent.panel.input_text)
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
    scroll = state.agentic.file_viewer_scroll
    rows = state.viewport.rows
    content_rows = max(rows - 1 - 1 - @input_height - 1 - 1, 1)

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
        input_text: panel.input_text,
        scroll_offset: panel.scroll_offset,
        spinner_frame: panel.spinner_frame,
        model_name: panel.model_name,
        thinking_level: panel.thinking_level
      },
      agentic: %{
        chat_width_pct: state.agentic.chat_width_pct,
        file_viewer_scroll: scroll
      },
      messages: messages,
      usage: usage,
      buffer_snapshot: buffer_snapshot,
      highlight: highlight,
      mode: state.mode,
      mode_state: state.mode_state,
      buf_index: state.buffers.active_index + 1,
      buf_count: length(state.buffers.list)
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

    left = " #{status_icon}  󰚩 #{panel.model_name}"
    center = "Minga Agent"
    right = if usage_text != "", do: "#{usage_text} ", else: ""

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

    [
      DisplayList.draw(row, 0, bar_text, fg: at.panel_border, bg: at.header_bg),
      DisplayList.draw(row, 1, status_icon, fg: status_fg, bg: at.header_bg, bold: true),
      DisplayList.draw(row, center_start, center,
        fg: at.header_fg,
        bg: at.header_bg,
        bold: true
      )
    ]
  end

  # ── Chat panel (messages only) ──────────────────────────────────────────────

  @spec render_chat_from_input(RenderInput.t(), rect()) :: [DisplayList.draw()]
  defp render_chat_from_input(input, rect) do
    panel_state = %{
      messages: input.messages,
      status: input.agent_status || :idle,
      input_text: input.panel.input_text,
      scroll_offset: input.panel.scroll_offset,
      spinner_frame: input.panel.spinner_frame,
      usage: input.usage,
      model_name: input.panel.model_name,
      thinking_level: input.panel.thinking_level,
      error_message: nil
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
  defp render_file_viewer_from_input(%{buffer_snapshot: nil}, {row_off, col_off, width, height}) do
    blank = String.duplicate(" ", width)

    for row <- 0..(height - 1) do
      DisplayList.draw(row_off + row, col_off, blank)
    end
  end

  defp render_file_viewer_from_input(input, {row_off, col_off, width, height}) do
    snapshot = input.buffer_snapshot
    scroll = input.agentic.file_viewer_scroll

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

    input_row = row + 1
    blank = String.duplicate(" ", cols)
    blank_cmd = DisplayList.draw(input_row, 0, blank, bg: at.input_bg)

    {text, fg} =
      if panel.input_text == "" do
        {"  Type a message, Enter to send", at.input_placeholder}
      else
        {"  " <> panel.input_text, at.text_fg}
      end

    text = String.slice(text, 0, cols)
    text_cmd = DisplayList.draw(input_row, 0, text, fg: fg, bg: at.input_bg)

    pad_cmd = DisplayList.draw(row + 2, 0, blank, bg: at.input_bg)

    [border_cmd, blank_cmd, text_cmd, pad_cmd]
  end

  # ── Modeline ────────────────────────────────────────────────────────────────

  @spec render_modeline_from_input(RenderInput.t(), non_neg_integer(), pos_integer()) ::
          [DisplayList.draw()]
  defp render_modeline_from_input(input, row, cols) do
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

  @spec spinner(non_neg_integer()) :: String.t()
  defp spinner(frame) do
    chars = ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    Enum.at(chars, rem(frame, length(chars)))
  end
end
