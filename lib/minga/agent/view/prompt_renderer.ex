defmodule Minga.Agent.View.PromptRenderer do
  @moduledoc """
  Renders the agent prompt input box: bordered text area with vim mode
  indicator, model info, visual selection, and paste block placeholders.

  Also exposes layout helpers (`input_box_width/1`, `input_inner_width/1`,
  `input_v_gap/0`, `compute_input_height/2`) used by `Input.AgentMouse`
  for hit-testing.

  Called by `Minga.Editor.RenderPipeline.Content` when rendering agent
  chat windows.
  """

  alias Minga.Agent.Config, as: AgentConfig
  alias Minga.Agent.UIState
  alias Minga.Agent.View.RenderInput
  alias Minga.Editor.DisplayList
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Face

  alias Minga.Input.Wrap, as: InputWrap
  alias Minga.Theme

  @typedoc "Screen rectangle {row_offset, col_offset, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @max_input_lines 8
  @input_h_margin 2
  @input_v_gap 1

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Computes the input prompt height for a given chat width.

  Used by the Content stage to determine how much space to reserve for
  the prompt at the bottom of the agent chat window.
  """
  @spec prompt_height(EditorState.t(), pos_integer()) :: pos_integer()
  def prompt_height(%EditorState{} = state, chat_width) do
    input = RenderInput.extract(state)
    box_width = max(chat_width - 2 * @input_h_margin, 10)
    compute_input_height(input.panel.input_lines, input_inner_width(box_width))
  end

  @doc """
  Renders only the prompt input area into the given rect.

  Used by the Content stage when the chat content is rendered through
  the standard buffer pipeline with decorations.
  """
  @spec render(EditorState.t(), rect()) :: [DisplayList.draw()]
  def render(%EditorState{} = state, {row, col, width, _height}) do
    input = RenderInput.extract(state)
    box_width = max(width - 2 * @input_h_margin, 10)
    box_col = col + @input_h_margin
    render_input_from_input(input, row, box_col, box_width)
  end

  @doc """
  Returns `{row, col}` for the cursor within a bounded content rect.

  Used by the render pipeline to position the cursor in the agent chat
  input area when the agent is hosted in a window pane. The rect
  determines the coordinate space.

  Returns nil when input is not focused (cursor hidden).
  """
  @spec cursor_position_in_rect(EditorState.t(), rect()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def cursor_position_in_rect(state, {row_off, col_off, width, height}) do
    panel = AgentAccess.panel(state)

    if panel.input_focused do
      view = AgentAccess.view(state)
      chat_width_pct = view.chat_width_pct
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

  # ── Layout helpers (public for AgentMouse hit-testing) ──────────────────────

  @doc """
  Computes the text width inside the input box, excluding borders and padding.

  Layout: "│" (1) + padding_left (3) + text + padding_right (1) + "│" (1) = 6 chars chrome.
  """
  @spec input_inner_width(pos_integer()) :: pos_integer()
  def input_inner_width(box_width), do: max(box_width - 6, 1)

  @doc """
  Returns the prompt box width after applying horizontal margins.

  The box is inset by `@input_h_margin` on each side of the chat column.
  """
  @spec input_box_width(pos_integer()) :: pos_integer()
  def input_box_width(chat_width), do: max(chat_width - 2 * @input_h_margin, 10)

  @doc """
  Returns the vertical gap (in rows) between the prompt box and the modeline.
  """
  @spec input_v_gap() :: non_neg_integer()
  def input_v_gap, do: @input_v_gap

  @doc """
  Computes the dynamic input area height for the bordered box:
  top border(1) + visible lines + bottom border(1).

  Uses visual line count (accounting for soft-wrap at inner_width).
  """
  @spec compute_input_height([String.t()], pos_integer()) :: pos_integer()
  def compute_input_height(input_lines, inner_width) do
    visible = InputWrap.visible_height(input_lines, inner_width, @max_input_lines)
    visible + 2
  end

  # ── Private rendering ───────────────────────────────────────────────────────

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
    border_style = Face.new(fg: at.input_border, bg: at.panel_bg)

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
          DisplayList.draw(content_start, col_off, "│" <> fill <> "│", Face.new(bg: at.input_bg)),
          DisplayList.draw(content_start, col_off, "│", border_style),
          DisplayList.draw(content_start, col_off + width - 1, "│", border_style),
          DisplayList.draw(
            content_start,
            col_off + 1 + pad_left,
            padded,
            Face.new(fg: at.input_placeholder, bg: at.input_bg)
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
      DisplayList.draw(row, c, "│" <> fill <> "│", Face.new(bg: chrome.input_bg)),
      DisplayList.draw(row, c, "│", chrome.border_style),
      DisplayList.draw(row, c + chrome.width - 1, "│", chrome.border_style),
      DisplayList.draw(row, text_col, padded, Face.new(fg: fg_color, bg: chrome.input_bg))
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
            DisplayList.draw(
              row,
              text_col + sel_start,
              sel_text,
              Face.new(fg: fg_color, bg: chrome.input_bg, reverse: true)
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
end
