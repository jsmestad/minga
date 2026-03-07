defmodule Minga.Agent.ChatRenderer do
  @moduledoc """
  Renders the AI agent chat panel into draw commands.

  Produces a list of `Protocol.encode_draw` commands for a given screen
  region, displaying the conversation with styled message blocks, markdown
  formatting, tool call cards, thinking indicators, and the input area.

  This is a custom renderer (like TreeRenderer, PickerUI) that works
  directly with draw primitives rather than going through a buffer.
  """

  alias Minga.Agent.Markdown
  alias Minga.Agent.Message
  alias Minga.Port.Protocol
  alias Minga.Theme

  @typedoc "Screen rectangle: {row_offset, col_offset, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc "Panel state for rendering."
  @type panel_state :: %{
          messages: [Message.t()],
          status: :idle | :thinking | :tool_executing | :error,
          input_text: String.t(),
          scroll_offset: non_neg_integer(),
          spinner_frame: non_neg_integer(),
          usage: map(),
          model_name: String.t(),
          thinking_level: String.t(),
          error_message: String.t() | nil
        }

  @spinner_chars ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @input_height 3

  @doc """
  Renders the chat panel into draw commands for the given screen rect.
  """
  @spec render(rect(), panel_state(), Theme.t()) :: [binary()]
  def render({row_off, col_off, width, height}, panel, theme) do
    at = Theme.agent_theme(theme)

    # Layout: header (1 row) + separator (1 row) + content (dynamic) + input area (3 rows)
    content_height = max(height - 2 - @input_height, 1)
    input_row = row_off + height - @input_height

    commands =
      []
      |> render_separator(row_off, col_off, width, at)
      |> render_header(row_off + 1, col_off, width, panel, at)
      |> render_content(row_off + 2, col_off, width, content_height, panel, at)
      |> render_input(input_row, col_off, width, panel, at)

    commands
  end

  @doc """
  Renders only the message content area (no header, no input, no separator).

  Used by the agentic view renderer, which handles the title bar and input
  area separately at full screen width.
  """
  @spec render_messages_only(rect(), panel_state(), Theme.t()) :: [binary()]
  def render_messages_only({row_off, col_off, width, height}, panel, theme) do
    at = Theme.agent_theme(theme)
    render_content([], row_off, col_off, width, height, panel, at)
  end

  # ── Separator line ──────────────────────────────────────────────────────────

  @spec render_separator(
          [binary()],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          Theme.Agent.t()
        ) :: [binary()]
  defp render_separator(cmds, row, col, width, at) do
    line = String.duplicate("─", width)
    [Protocol.encode_draw(row, col, line, fg: at.panel_border, bg: at.panel_bg) | cmds]
  end

  # ── Header ──────────────────────────────────────────────────────────────────

  @spec render_header(
          [binary()],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          panel_state(),
          Theme.Agent.t()
        ) :: [binary()]
  defp render_header(cmds, row, col, width, panel, at) do
    model = " 󰚩 #{panel.model_name} "
    usage_text = format_usage(panel.usage)

    status_icon =
      case panel.status do
        :idle -> "◯"
        :thinking -> spinner(panel.spinner_frame)
        :tool_executing -> "⚡"
        :error -> "✗"
      end

    status_fg =
      case panel.status do
        :idle -> at.status_idle
        :thinking -> at.status_thinking
        :tool_executing -> at.status_tool
        :error -> at.status_error
      end

    left = " #{status_icon} │ #{model}"
    right = "#{usage_text} "
    padding = max(width - String.length(left) - String.length(right), 0)
    padded_left = left <> String.duplicate(" ", padding)

    cmds = [
      Protocol.encode_draw(row, col, padded_left, fg: at.header_fg, bg: at.header_bg),
      Protocol.encode_draw(row, col, " #{status_icon} ",
        fg: status_fg,
        bg: at.header_bg,
        bold: true
      ),
      Protocol.encode_draw(row, col + String.length(padded_left), right,
        fg: at.header_fg,
        bg: at.header_bg
      )
      | cmds
    ]

    cmds
  end

  # ── Content area ────────────────────────────────────────────────────────────

  @spec render_content(
          [binary()],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          panel_state(),
          Theme.Agent.t()
        ) :: [binary()]
  defp render_content(cmds, row_start, col, width, content_height, panel, at) do
    lines = messages_to_lines(panel.messages, panel.status, panel.spinner_frame, at, width)

    # Apply scroll offset
    total = length(lines)
    scroll = min(panel.scroll_offset, max(total - content_height, 0))
    visible = lines |> Enum.drop(scroll) |> Enum.take(content_height)

    # Render visible lines.
    # The Zig renderer processes commands head-to-tail, so the background
    # fill must appear BEFORE its row's segments in the final list
    # (background painted first, text drawn on top). We accumulate each
    # row's commands in forward order and append to the list.
    {row_cmds_acc, _row} =
      Enum.reduce(visible, {[], row_start}, fn {segments, _type, bg}, {acc, row} ->
        blank = String.duplicate(" ", width)
        bg_cmd = Protocol.encode_draw(row, col, blank, bg: bg)

        right_edge = col + width

        {seg_cmds_rev, _} =
          Enum.reduce(segments, {[], col}, fn {text, style_opts}, {seg_acc, c} ->
            render_segment(seg_acc, row, c, text, style_opts, right_edge)
          end)

        # Forward order: bg first, then segments
        row_cmds = [bg_cmd | Enum.reverse(seg_cmds_rev)]
        {acc ++ row_cmds, row + 1}
      end)

    cmds = cmds ++ row_cmds_acc

    # Fill remaining rows with empty background
    remaining = content_height - length(visible)

    cmds =
      if remaining > 0 do
        blank = String.duplicate(" ", width)
        start_row = row_start + length(visible)

        Enum.reduce(0..(remaining - 1), cmds, fn i, acc ->
          [Protocol.encode_draw(start_row + i, col, blank, bg: at.panel_bg) | acc]
        end)
      else
        cmds
      end

    cmds
  end

  # ── Input area ──────────────────────────────────────────────────────────────

  @spec render_input(
          [binary()],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          panel_state(),
          Theme.Agent.t()
        ) :: [binary()]
  defp render_input(cmds, row, col, width, panel, at) do
    # Border line
    label = "─── Prompt "
    border_rest = String.duplicate("─", max(width - String.length(label), 0))
    border = label <> border_rest

    cmds = [Protocol.encode_draw(row, col, border, fg: at.input_border, bg: at.panel_bg) | cmds]

    # Input text or placeholder
    input_row = row + 1
    blank = String.duplicate(" ", width)
    cmds = [Protocol.encode_draw(input_row, col, blank, bg: at.input_bg) | cmds]

    {text, fg} =
      if panel.input_text == "" do
        {"  Type a message, C-c C-c to send", at.input_placeholder}
      else
        {"  " <> panel.input_text, at.text_fg}
      end

    text = String.slice(text, 0, width)
    cmds = [Protocol.encode_draw(input_row, col, text, fg: fg, bg: at.input_bg) | cmds]

    # Bottom padding
    cmds = [Protocol.encode_draw(row + 2, col, blank, bg: at.input_bg) | cmds]

    cmds
  end

  # ── Message → line conversion ───────────────────────────────────────────────

  @typedoc "A renderable line: {styled_segments, line_type, background_color}."
  @type render_line :: {[{String.t(), keyword()}], Markdown.line_type(), Theme.color()}

  @spec messages_to_lines(
          [Message.t()],
          atom(),
          non_neg_integer(),
          Theme.Agent.t(),
          pos_integer()
        ) :: [render_line()]
  defp messages_to_lines(messages, status, spinner_frame, at, width) do
    lines =
      Enum.flat_map(messages, fn msg ->
        message_lines(msg, at, width)
      end)

    # Add thinking indicator if active
    if status == :thinking do
      char = spinner(spinner_frame)

      indicator =
        {[{"  #{char} Thinking...", [fg: at.thinking_fg, italic: true]}], :text, at.panel_bg}

      Enum.reverse([indicator | Enum.reverse(lines)])
    else
      lines
    end
  end

  @spec message_lines(Message.t(), Theme.Agent.t(), pos_integer()) :: [render_line()]

  defp message_lines({:user, text}, at, width) do
    header = {[{"▎ You", [fg: at.user_label, bold: true]}], :text, at.panel_bg}
    content = text_to_lines(text, at, width, at.user_border)
    spacer = {[{"", []}], :empty, at.panel_bg}
    [header | content] ++ [spacer]
  end

  defp message_lines({:assistant, text}, at, _width) do
    header = {[{"▎ Agent", [fg: at.assistant_label, bold: true]}], :text, at.panel_bg}

    parsed = Markdown.parse(text)

    content =
      Enum.map(parsed, fn {segments, line_type} ->
        styled = Enum.map(segments, fn {t, style} -> {t, style_to_opts(style, at)} end)

        bg =
          case line_type do
            :code -> at.code_bg
            _ -> at.panel_bg
          end

        {[{"▎ ", [fg: at.assistant_border]} | styled], line_type, bg}
      end)

    spacer = {[{"", []}], :empty, at.panel_bg}
    [header | content] ++ [spacer]
  end

  defp message_lines({:thinking, text}, at, _width) do
    lines = String.split(text, "\n")

    header =
      {[{"  💭 Thinking", [fg: at.thinking_fg, italic: true, bold: true]}], :text, at.panel_bg}

    content =
      Enum.map(lines, fn line ->
        {[{"  │ " <> line, [fg: at.thinking_fg, italic: true]}], :text, at.panel_bg}
      end)

    spacer = {[{"", []}], :empty, at.panel_bg}
    [header | content] ++ [spacer]
  end

  defp message_lines({:tool_call, tc}, at, _width) do
    status_icon =
      case tc.status do
        :running -> "⟳"
        :complete -> "✓"
        :error -> "✗"
      end

    status_fg =
      case tc.status do
        :running -> at.status_thinking
        :complete -> at.assistant_border
        :error -> at.status_error
      end

    header_text = "  ┌─ #{status_icon} #{tc.name} "
    args_text = format_tool_args(tc.args)

    header =
      {[{header_text, [fg: at.tool_header, bold: true]}, {args_text, [fg: at.tool_border]}],
       :text, at.panel_bg}

    result_lines =
      if tc.collapsed or tc.result == "" do
        []
      else
        tc.result
        |> String.split("\n")
        |> Enum.take(5)
        |> Enum.map(fn line ->
          truncated = String.slice(line, 0, 80)
          {[{"  │ " <> truncated, [fg: at.text_fg]}], :text, at.panel_bg}
        end)
      end

    footer =
      if tc.collapsed and tc.result != "" do
        preview = tc.result |> String.split("\n") |> hd() |> String.slice(0, 60)

        {[{"  └─ ", [fg: at.tool_border]}, {preview <> "...", [fg: at.text_fg]}], :text,
         at.panel_bg}
      else
        {[{"  └─", [fg: at.tool_border]}, {" #{status_icon}", [fg: status_fg]}], :text,
         at.panel_bg}
      end

    spacer = {[{"", []}], :empty, at.panel_bg}
    [header | result_lines] ++ [footer, spacer]
  end

  # ── Style conversion ────────────────────────────────────────────────────────

  @spec style_to_opts(Markdown.style(), Theme.Agent.t()) :: keyword()
  defp style_to_opts(:plain, at), do: [fg: at.text_fg]
  defp style_to_opts(:bold, at), do: [fg: at.text_fg, bold: true]
  defp style_to_opts(:italic, at), do: [fg: at.text_fg, italic: true]
  defp style_to_opts(:bold_italic, at), do: [fg: at.text_fg, bold: true, italic: true]
  defp style_to_opts(:code, at), do: [fg: at.text_fg, bg: at.code_bg]
  defp style_to_opts(:code_block, at), do: [fg: at.text_fg, bg: at.code_bg]
  defp style_to_opts(:header1, at), do: [fg: at.assistant_label, bold: true]
  defp style_to_opts(:header2, at), do: [fg: at.assistant_label, bold: true]
  defp style_to_opts(:header3, at), do: [fg: at.assistant_label]
  defp style_to_opts(:blockquote, at), do: [fg: at.thinking_fg, italic: true]
  defp style_to_opts(:list_bullet, at), do: [fg: at.assistant_border]
  defp style_to_opts(:rule, at), do: [fg: at.panel_border]

  # ── Segment rendering ────────────────────────────────────────────────────────

  # Renders a single text segment, truncating at the panel's right edge.
  @spec render_segment(
          [binary()],
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          keyword(),
          non_neg_integer()
        ) :: {[binary()], non_neg_integer()}
  defp render_segment(acc, _row, col, _text, _style_opts, right_edge) when col >= right_edge do
    {acc, col}
  end

  defp render_segment(acc, row, col, text, style_opts, right_edge) do
    remaining = right_edge - col
    truncated = String.slice(text, 0, remaining)
    draw = Protocol.encode_draw(row, col, truncated, style_opts)
    {[draw | acc], col + String.length(truncated)}
  end

  # ── Text helpers ────────────────────────────────────────────────────────────

  @spec text_to_lines(String.t(), Theme.Agent.t(), pos_integer(), Theme.color()) :: [
          render_line()
        ]
  defp text_to_lines(text, at, _width, border_color) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      {[{"▎ ", [fg: border_color]}, {line, [fg: at.text_fg]}], :text, at.panel_bg}
    end)
  end

  @spec format_usage(map()) :: String.t()
  defp format_usage(%{input: i, output: o, cost: c}) when i > 0 do
    "↑#{format_tokens(i)} ↓#{format_tokens(o)} $#{Float.round(c, 3)}"
  end

  defp format_usage(_), do: ""

  @spec format_tokens(non_neg_integer()) :: String.t()
  defp format_tokens(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_tokens(n), do: "#{n}"

  @spec format_tool_args(map()) :: String.t()
  defp format_tool_args(args) when map_size(args) == 0, do: ""

  defp format_tool_args(args) do
    args
    |> Enum.take(2)
    |> Enum.map_join(", ", fn {k, v} ->
      val = v |> inspect() |> String.slice(0, 30)
      "#{k}: #{val}"
    end)
    |> then(&("(" <> &1 <> ")"))
  end

  @spec spinner(non_neg_integer()) :: String.t()
  defp spinner(frame) do
    Enum.at(@spinner_chars, rem(frame, length(@spinner_chars)))
  end
end
