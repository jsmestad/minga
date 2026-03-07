defmodule Minga.Agent.View.Renderer do
  @moduledoc """
  Full-screen agentic view renderer.

  Produces draw commands for a two-panel layout: chat panel on the left (~65%
  width, full height) and a read-only file viewer on the right (~35%). A
  vertical separator divides the panels. The modeline sits at row `rows - 2`
  and the minibuffer is always reserved at the absolute last row.

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

  @chat_width_pct 65
  # Input area rows inside the ChatRenderer: border + text + padding
  @input_height 3

  @doc """
  Renders the full-screen agentic view and returns a flat list of draw commands.

  The caller (Renderer.render_agentic/1) prepends a clear command and appends
  the cursor, cursor-shape, and batch-end commands before sending.
  """
  @spec render(state()) :: [binary()]
  def render(state) do
    total_cols = state.viewport.cols
    total_rows = state.viewport.rows

    # Layout: last row = minibuffer, second-to-last row = modeline.
    # Content height for the panels is everything above the minibuffer row.
    content_height = total_rows - 1

    chat_width = max(div(total_cols * @chat_width_pct, 100), 20)
    separator_col = chat_width
    viewer_col = chat_width + 1
    viewer_width = max(total_cols - viewer_col, 10)

    # The chat panel gets full content height; it draws the separator row and
    # header internally.
    chat_rect = {0, 0, chat_width, content_height}
    viewer_rect = {0, viewer_col, viewer_width, content_height}

    chat_commands = render_chat(state, chat_rect)
    separator_commands = render_separator(separator_col, content_height, state.theme)
    viewer_commands = render_file_viewer(state, viewer_rect)
    modeline_commands = render_agentic_modeline(state, total_cols)

    chat_commands ++ separator_commands ++ viewer_commands ++ modeline_commands
  end

  @doc """
  Returns `{row, col}` for where the terminal cursor should be placed.

  When the chat input is focused the cursor goes into the input text field.
  Otherwise the cursor is hidden off-screen (bottom-right corner).
  """
  @spec cursor_position(state()) :: {non_neg_integer(), non_neg_integer()}
  def cursor_position(state) do
    total_rows = state.viewport.rows
    content_height = total_rows - 1

    if state.agent.panel.input_focused do
      # The ChatRenderer places the input text at content_height - @input_height + 1
      # (0-based: border is at -3, text is at -2 from content_height).
      input_text_row = content_height - @input_height + 1
      # "  " prefix + typed text
      input_col = 2 + String.length(state.agent.panel.input_text)
      {input_text_row, input_col}
    else
      {total_rows, 0}
    end
  end

  # ── Chat panel ──────────────────────────────────────────────────────────────

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

    ChatRenderer.render(rect, panel_state, state.theme)
  end

  # ── Vertical separator ──────────────────────────────────────────────────────

  @spec render_separator(non_neg_integer(), pos_integer(), Theme.t()) :: [binary()]
  defp render_separator(col, height, theme) do
    at = Theme.agent_theme(theme)

    for row <- 0..(height - 1) do
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

    # Reserve the last row in the viewer panel for a filename header bar.
    content_rows = max(height - 1, 1)

    snapshot = BufferServer.render_snapshot(buf, scroll, content_rows)
    lines = snapshot.lines
    line_count = snapshot.line_count

    # Absolute column positions on the full terminal screen. Use max/2 so
    # Dialyzer can prove these are non_neg_integer() for Gutter.render_number.
    abs_gutter_col = max(col_off, 0)
    local_gutter_w = file_viewer_gutter_width(line_count)
    abs_content_col = col_off + local_gutter_w
    content_w = max(width - local_gutter_w, 1)

    viewer_vp = Viewport.new(content_rows, width)
    viewer_vp = %{viewer_vp | top: scroll}

    highlight =
      if state.highlight.current.capture_names != [], do: state.highlight.current, else: nil

    # gutter_w in Context is the absolute content column (LineRenderer uses it
    # as the draw col for content). This lets us skip post-hoc offset patching.
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
          abs_row = max(row_off + screen_row, 0)

          # cursor_line is irrelevant for :absolute style; pass 0 to satisfy the
          # non_neg_integer() spec (absolute mode ignores it entirely).
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
        tilde_start = row_off + length(lines)
        tilde_end = row_off + content_rows - 1

        for r <- tilde_start..tilde_end do
          Protocol.encode_draw(r, abs_content_col, "~", fg: state.theme.editor.tilde_fg)
        end
      else
        []
      end

    # File name header bar at the bottom of the viewer panel.
    header_row = row_off + height - 1
    at = Theme.agent_theme(state.theme)
    file_name = snapshot_display_name(snapshot)
    header_text = String.pad_trailing(" #{file_name}", width)

    header_cmd =
      Protocol.encode_draw(header_row, col_off, header_text, fg: at.header_fg, bg: at.header_bg)

    [header_cmd | gutter_cmds] ++ line_cmds ++ tilde_cmds
  end

  # ── Agentic modeline ────────────────────────────────────────────────────────

  @spec render_agentic_modeline(state(), pos_integer()) :: [binary()]
  defp render_agentic_modeline(state, cols) do
    # Row: second-to-last row (minibuffer is the very last row).
    row = state.viewport.rows - 2

    Modeline.render(
      row,
      cols,
      %{
        mode: state.mode,
        mode_state: state.mode_state,
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
    # digit columns + 1 space separator
    digits + 1
  end

  @spec snapshot_display_name(map()) :: String.t()
  defp snapshot_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp snapshot_display_name(_), do: "[No Name]"

  @spec empty_usage() :: map()
  defp empty_usage, do: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}
end
