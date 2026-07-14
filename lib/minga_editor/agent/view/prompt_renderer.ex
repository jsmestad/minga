defmodule MingaEditor.Agent.View.PromptRenderer do
  @moduledoc """
  Prompt-input layout math for the agent chat window.

  This module owns the geometry of the bordered prompt box: its width, inner
  text width, dynamic height, the vertical gap above the modeline, and the
  cursor position inside a bounded content rect. The render pipeline and
  `Input.AgentMouse` use these helpers for layout and hit-testing.

  The visible prompt is drawn by the semantic surfaces: the prompt buffer is a
  `RenderWindow` built by `MingaEditor.Agent.View.PromptRenderWindow`, and the
  surrounding chrome (model line, mode, completion) rides the `AgentChat`
  semantic model built by `MingaEditor.RenderModel.UI.AgentChatBuilder`. The
  cell-era draw path that previously lived here was retired in #2221 once both
  live frontends became semantic-only; this module keeps only the layout API
  those surfaces still depend on.
  """

  alias MingaEditor.Agent.ViewContext

  alias MingaEditor.Input.Wrap, as: InputWrap

  @typedoc "Screen rectangle {row_offset, col_offset, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @max_input_lines 8
  @input_h_margin 2
  @input_pad_left 1
  @input_pad_right 1
  @input_v_gap 1

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Computes the input prompt height for a given chat width.

  Used by the Content stage to determine how much space to reserve for
  the prompt at the bottom of the agent chat window.
  """
  @spec prompt_height(ViewContext.t(), pos_integer()) :: pos_integer()
  def prompt_height(%ViewContext{} = ctx, chat_width) do
    input_lines = MingaEditor.Agent.PromptBuffer.input_lines(ctx.ui_state.panel)
    box_width = max(chat_width - 2 * @input_h_margin, 10)
    compute_input_height(input_lines, input_inner_width(box_width))
  end

  @doc """
  Returns `{row, col}` for the cursor within a bounded content rect.

  Used by the render pipeline to position the cursor in the agent chat
  input area when the agent is hosted in a window pane. The rect
  determines the coordinate space.

  Returns nil when input is not focused (cursor hidden).
  """
  @spec cursor_position_in_rect(ViewContext.t(), rect()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def cursor_position_in_rect(ctx, {row_off, col_off, width, height}) do
    panel = ctx.ui_state.panel

    if panel.input_focused do
      view = ctx.ui_state.view
      chat_width_pct = view.chat_width_pct
      chat_width = max(div(width * chat_width_pct, 100), 20)
      box_width = max(chat_width - 2 * @input_h_margin, 10)
      box_col = col_off + @input_h_margin
      inner_width = input_inner_width(box_width)

      lines = MingaEditor.Agent.PromptBuffer.input_lines(panel)
      cursor = MingaEditor.Agent.PromptBuffer.input_cursor(panel)

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
      input_col = box_col + 1 + @input_pad_left + visual_col
      {input_text_row, input_col}
    else
      nil
    end
  end

  # ── Layout helpers (public for AgentMouse hit-testing) ──────────────────────

  @doc """
  Computes the text width inside the input box, excluding borders and padding.

  Layout: "│" (1) + padding_left + text + padding_right + "│" (1).
  """
  @spec input_inner_width(pos_integer()) :: pos_integer()
  def input_inner_width(box_width), do: max(box_width - input_chrome_width(), 1)

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

  @spec input_chrome_width() :: pos_integer()
  defp input_chrome_width, do: 2 + @input_pad_left + @input_pad_right

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
end
