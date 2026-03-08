defmodule Minga.Agent.ChatRenderer do
  @moduledoc """
  Renders the AI agent chat panel into draw tuples.

  Produces a list of `DisplayList.draw()` tuples for a given screen
  region, displaying the conversation with styled message blocks, markdown
  formatting, tool call cards, thinking indicators, and the input area.

  This is a custom renderer (like TreeRenderer, PickerUI) that works
  directly with draw primitives rather than going through a buffer.
  """

  alias Minga.Agent.Markdown
  alias Minga.Agent.Message
  alias Minga.Agent.WordWrap
  alias Minga.Editor.DisplayList
  alias Minga.Theme

  @typedoc "Screen rectangle: {row_offset, col_offset, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc "Panel state for rendering."
  @type panel_state :: %{
          messages: [Message.t()],
          status: :idle | :thinking | :tool_executing | :error,
          input_lines: [String.t()],
          input_cursor: {non_neg_integer(), non_neg_integer()},
          scroll_offset: non_neg_integer(),
          spinner_frame: non_neg_integer(),
          usage: map(),
          model_name: String.t(),
          thinking_level: String.t(),
          error_message: String.t() | nil,
          auto_scroll: boolean(),
          display_start_index: non_neg_integer()
        }

  @spinner_chars ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @input_height 3

  @doc """
  Renders the chat panel into draw tuples for the given screen rect.
  """
  @spec render(rect(), panel_state(), Theme.t()) :: [DisplayList.draw()]
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
  @spec render_messages_only(rect(), panel_state(), Theme.t()) :: [DisplayList.draw()]
  def render_messages_only({row_off, col_off, width, height}, panel, theme) do
    at = Theme.agent_theme(theme)
    render_content([], row_off, col_off, width, height, panel, at)
  end

  @typedoc "Line type for line-to-message mapping."
  @type line_type :: :text | :code | :tool | :thinking | :system | :empty

  @doc """
  Builds a line-to-message index map for the visible messages.

  Returns a list of `{message_index, line_type}` tuples, one per rendered
  line. The `display_start_index` from the panel state is applied first,
  so message indices are relative to the full (unfiltered) message list.
  """
  @spec line_message_map([Message.t()], pos_integer(), Theme.t(), non_neg_integer()) :: [
          {non_neg_integer(), line_type()}
        ]
  def line_message_map(messages, width, theme, display_start_index \\ 0) do
    at = Theme.agent_theme(theme)
    visible = Enum.drop(messages, display_start_index)

    visible
    |> Enum.with_index(display_start_index)
    |> Enum.flat_map(fn {msg, msg_idx} ->
      lines = message_lines(msg, at, width)
      Enum.map(lines, fn {_segments, type, _bg} -> {msg_idx, classify_line_type(type)} end)
    end)
  end

  @spec classify_line_type(atom()) :: line_type()
  defp classify_line_type(:code), do: :code
  defp classify_line_type(:empty), do: :empty
  defp classify_line_type(_), do: :text

  # ── Separator line ──────────────────────────────────────────────────────────

  @spec render_separator(
          [DisplayList.draw()],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          Theme.Agent.t()
        ) :: [DisplayList.draw()]
  defp render_separator(cmds, row, col, width, at) do
    line = String.duplicate("─", width)
    [DisplayList.draw(row, col, line, fg: at.panel_border, bg: at.panel_bg) | cmds]
  end

  # ── Header ──────────────────────────────────────────────────────────────────

  @spec render_header(
          [DisplayList.draw()],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          panel_state(),
          Theme.Agent.t()
        ) :: [DisplayList.draw()]
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
      DisplayList.draw(row, col, padded_left, fg: at.header_fg, bg: at.header_bg),
      DisplayList.draw(row, col, " #{status_icon} ",
        fg: status_fg,
        bg: at.header_bg,
        bold: true
      ),
      DisplayList.draw(row, col + String.length(padded_left), right,
        fg: at.header_fg,
        bg: at.header_bg
      )
      | cmds
    ]

    cmds
  end

  # ── Content area ────────────────────────────────────────────────────────────

  @spec render_content(
          [DisplayList.draw()],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          panel_state(),
          Theme.Agent.t()
        ) :: [DisplayList.draw()]
  defp render_content(cmds, row_start, col, width, content_height, panel, at) do
    display_start = Map.get(panel, :display_start_index, 0)
    visible_messages = Enum.drop(panel.messages, display_start)
    lines = messages_to_lines(visible_messages, panel.status, panel.spinner_frame, at, width)

    # Apply scroll offset
    total = length(lines)
    scroll = min(panel.scroll_offset, max(total - content_height, 0))
    visible = lines |> Enum.drop(scroll) |> Enum.take(content_height)

    # Render visible lines.
    # Background fill must appear BEFORE its row's segments in the final list
    # (background painted first, text drawn on top).
    {row_cmds_acc, _row} =
      Enum.reduce(visible, {[], row_start}, fn {segments, _type, bg}, {acc, row} ->
        blank = String.duplicate(" ", width)
        bg_cmd = DisplayList.draw(row, col, blank, bg: bg)

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
          [DisplayList.draw(start_row + i, col, blank, bg: at.panel_bg) | acc]
        end)
      else
        cmds
      end

    # "↓ new" indicator when auto-scroll is disengaged and content is below viewport
    has_content_below = scroll + content_height < total
    auto_scroll = Map.get(panel, :auto_scroll, true)
    is_streaming = panel.status in [:thinking, :tool_executing]

    if not auto_scroll and has_content_below and is_streaming do
      indicator_row = row_start + content_height - 1
      label = " ↓ new "
      indicator_col = col + width - String.length(label)

      [
        DisplayList.draw(indicator_row, indicator_col, label,
          fg: at.panel_bg,
          bg: at.assistant_label,
          bold: true
        )
        | cmds
      ]
    else
      cmds
    end
  end

  # ── Input area ──────────────────────────────────────────────────────────────

  @spec render_input(
          [DisplayList.draw()],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          panel_state(),
          Theme.Agent.t()
        ) :: [DisplayList.draw()]
  defp render_input(cmds, row, col, width, panel, at) do
    # Border line
    label = "─── Prompt "
    border_rest = String.duplicate("─", max(width - String.length(label), 0))
    border = label <> border_rest

    cmds = [DisplayList.draw(row, col, border, fg: at.input_border, bg: at.panel_bg) | cmds]

    blank = String.duplicate(" ", width)

    is_empty = panel.input_lines == [""]

    if is_empty do
      # Placeholder
      input_row = row + 1
      cmds = [DisplayList.draw(input_row, col, blank, bg: at.input_bg) | cmds]
      placeholder = String.slice("  Type a message, C-c C-c to send", 0, width)

      cmds = [
        DisplayList.draw(input_row, col, placeholder, fg: at.input_placeholder, bg: at.input_bg)
        | cmds
      ]

      [DisplayList.draw(row + 2, col, blank, bg: at.input_bg) | cmds]
    else
      # Render the first visible line (in the side panel we only show 1 line)
      input_row = row + 1
      cmds = [DisplayList.draw(input_row, col, blank, bg: at.input_bg) | cmds]

      first_line = "  " <> (List.first(panel.input_lines) || "")
      line_count = length(panel.input_lines)
      indicator = if line_count > 1, do: " [#{line_count}L]", else: ""
      display = String.slice(first_line <> indicator, 0, width)

      cmds = [DisplayList.draw(input_row, col, display, fg: at.text_fg, bg: at.input_bg) | cmds]
      [DisplayList.draw(row + 2, col, blank, bg: at.input_bg) | cmds]
    end
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

      lines ++ [indicator]
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

  defp message_lines({:assistant, text}, at, width) do
    header = {[{"▎ Agent", [fg: at.assistant_label, bold: true]}], :text, at.panel_bg}

    parsed = Markdown.parse(text)
    border_prefix = [{"▎ ", [fg: at.assistant_border]}]
    # Available width after the border prefix
    content_width = max(width - 2, 4)

    content =
      Enum.flat_map(parsed, fn {segments, line_type} ->
        styled = Enum.map(segments, fn {t, style} -> {t, style_to_opts(style, at)} end)
        wrap_or_truncate(styled, line_type, border_prefix, content_width, at)
      end)

    spacer = {[{"", []}], :empty, at.panel_bg}
    [header | content] ++ [spacer]
  end

  defp message_lines({:thinking, text, true}, at, width) do
    lines = String.split(text, "\n")
    line_count = length(lines)
    preview = lines |> hd() |> String.slice(0, max(width - 30, 10))
    summary = "  💭 Thinking (#{line_count} lines): #{preview}..."

    [
      {[{String.slice(summary, 0, width), [fg: at.thinking_fg, italic: true]}], :text,
       at.panel_bg}
    ]
  end

  defp message_lines({:thinking, text, false}, at, width) do
    prefix = [{"  │ ", [fg: at.thinking_fg, italic: true]}]
    content_width = max(width - 4, 4)

    header =
      {[{"  💭 Thinking", [fg: at.thinking_fg, italic: true, bold: true]}], :text, at.panel_bg}

    content =
      text
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        wrap_or_truncate(
          [{line, [fg: at.thinking_fg, italic: true]}],
          :text,
          prefix,
          content_width,
          at
        )
      end)

    spacer = {[{"", []}], :empty, at.panel_bg}
    [header | content] ++ [spacer]
  end

  defp message_lines({:tool_call, tc}, at, width) do
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

    timing = format_tool_timing(tc)
    header_text = "  ┌─ #{status_icon} #{tc.name}#{timing} "
    args_text = format_tool_args(tc.args)

    header =
      {[{header_text, [fg: at.tool_header, bold: true]}, {args_text, [fg: at.tool_border]}],
       :text, at.panel_bg}

    result_lines =
      if tc.collapsed or tc.result == "" do
        []
      else
        tool_prefix = [{"  │ ", [fg: at.tool_border]}]
        tool_content_width = max(width - 4, 4)

        tc.result
        |> String.split("\n")
        |> Enum.take(5)
        |> Enum.flat_map(fn line ->
          wrap_or_truncate([{line, [fg: at.text_fg]}], :text, tool_prefix, tool_content_width, at)
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

  defp message_lines({:usage, usage}, at, width) do
    text = format_turn_usage(usage)
    padding = max(width - String.length(text) - 4, 0)

    [
      {[
         {"  ", []},
         {String.duplicate(" ", padding), []},
         {text, [fg: at.usage_fg]}
       ], :text, at.panel_bg}
    ]
  end

  defp message_lines({:system, text, level}, at, width) do
    fg =
      case level do
        :error -> at.status_error
        :info -> at.panel_border
      end

    # Center the text with ── decorations on both sides
    label = " #{text} "
    label_len = String.length(label)
    available = max(width - 2, 0)

    {left_rule, right_rule} =
      if label_len >= available do
        {"", ""}
      else
        remaining = available - label_len
        left = div(remaining, 2)
        right = remaining - left
        {String.duplicate("─", left), String.duplicate("─", right)}
      end

    line =
      {[
         {" ", []},
         {left_rule, [fg: fg]},
         {label, [fg: fg, italic: true]},
         {right_rule, [fg: fg]}
       ], :text, at.panel_bg}

    [line]
  end

  # ── Wrapping / truncation helpers ─────────────────────────────────────────────

  # Wraps prose lines or truncates code lines, returning render_line tuples.
  @spec wrap_or_truncate(
          [{String.t(), keyword()}],
          Markdown.line_type(),
          [{String.t(), keyword()}],
          pos_integer(),
          Theme.Agent.t()
        ) :: [render_line()]
  defp wrap_or_truncate(styled, :code, prefix, width, at) do
    [{prefix ++ truncate_code(styled, width, at), :code, at.code_bg}]
  end

  defp wrap_or_truncate(styled, line_type, prefix, width, at) do
    styled
    |> WordWrap.wrap_segments(width)
    |> Enum.map(fn line_segments -> {prefix ++ line_segments, line_type, at.panel_bg} end)
  end

  # ── Code truncation ──────────────────────────────────────────────────────────

  # Truncates a code line's segments to fit within width, appending a → indicator if truncated.
  @spec truncate_code([{String.t(), keyword()}], pos_integer(), Theme.Agent.t()) :: [
          {String.t(), keyword()}
        ]
  defp truncate_code(segments, max_width, at) do
    total =
      Enum.reduce(segments, 0, fn {text, _}, acc -> acc + String.length(text) end)

    if total <= max_width do
      segments
    else
      indicator = {"→", [fg: at.panel_border, bg: at.code_bg]}
      truncate_segments(segments, max_width - 1) ++ [indicator]
    end
  end

  @spec truncate_segments([{String.t(), keyword()}], non_neg_integer()) :: [
          {String.t(), keyword()}
        ]
  defp truncate_segments(segments, max_width) do
    {result, _remaining} =
      Enum.reduce_while(segments, {[], max_width}, fn {text, style}, {acc, remaining} ->
        len = String.length(text)

        cond do
          remaining <= 0 ->
            {:halt, {acc, 0}}

          len <= remaining ->
            {:cont, {[{text, style} | acc], remaining - len}}

          true ->
            truncated = String.slice(text, 0, remaining)
            {:halt, {[{truncated, style} | acc], 0}}
        end
      end)

    Enum.reverse(result)
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
          [DisplayList.draw()],
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          keyword(),
          non_neg_integer()
        ) :: {[DisplayList.draw()], non_neg_integer()}
  defp render_segment(acc, _row, col, _text, _style_opts, right_edge) when col >= right_edge do
    {acc, col}
  end

  defp render_segment(acc, row, col, text, style_opts, right_edge) do
    remaining = right_edge - col
    truncated = String.slice(text, 0, remaining)
    d = DisplayList.draw(row, col, truncated, style_opts)
    {[d | acc], col + String.length(truncated)}
  end

  # ── Text helpers ────────────────────────────────────────────────────────────

  @spec text_to_lines(String.t(), Theme.Agent.t(), pos_integer(), Theme.color()) :: [
          render_line()
        ]
  defp text_to_lines(text, at, width, border_color) do
    border_prefix = [{"▎ ", [fg: border_color]}]
    content_width = max(width - 2, 4)

    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      segments = [{line, [fg: at.text_fg]}]
      wrapped = WordWrap.wrap_segments(segments, content_width)

      Enum.map(wrapped, fn line_segments ->
        {border_prefix ++ line_segments, :text, at.panel_bg}
      end)
    end)
  end

  @spec format_usage(map()) :: String.t()
  defp format_usage(%{input: i, output: o, cost: c}) when i > 0 do
    "↑#{format_tokens(i)} ↓#{format_tokens(o)} $#{Float.round(c, 3)}"
  end

  defp format_usage(_), do: ""

  @spec format_turn_usage(map()) :: String.t()
  defp format_turn_usage(%{input: i, output: o, cache_read: cr, cache_write: cw, cost: c}) do
    cache_part =
      if cr > 0 or cw > 0 do
        cache = "cache:#{format_tokens(cr)}"
        if cw > 0, do: " " <> cache <> "/#{format_tokens(cw)}w", else: " " <> cache
      else
        ""
      end

    "↑#{format_tokens(i)} ↓#{format_tokens(o)}#{cache_part} $#{Float.round(c, 3)}"
  end

  defp format_turn_usage(%{input: i, output: o, cost: c}) do
    "↑#{format_tokens(i)} ↓#{format_tokens(o)} $#{Float.round(c, 3)}"
  end

  @spec format_tool_timing(map()) :: String.t()
  defp format_tool_timing(%{status: :running, started_at: started_at})
       when is_integer(started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    " (#{format_duration(elapsed)})"
  end

  defp format_tool_timing(%{duration_ms: ms}) when is_integer(ms) do
    " (#{format_duration(ms)})"
  end

  defp format_tool_timing(_), do: ""

  @spec format_duration(integer()) :: String.t()
  defp format_duration(ms) when ms >= 60_000 do
    minutes = div(ms, 60_000)
    seconds = Float.round(rem(ms, 60_000) / 1000, 1)
    "#{minutes}m#{seconds}s"
  end

  defp format_duration(ms) when ms >= 1000 do
    "#{Float.round(ms / 1000, 1)}s"
  end

  defp format_duration(ms), do: "#{ms}ms"

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
