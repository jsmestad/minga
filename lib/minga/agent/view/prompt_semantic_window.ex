defmodule Minga.Agent.View.PromptSemanticWindow do
  @moduledoc """
  Builds a `SemanticWindow` from the agent prompt buffer state.

  Translates prompt buffer content, cursor position, vim mode, visual
  selection, and paste placeholder lines into the same `SemanticWindow`
  struct used by the GUI window content pipeline (0x80 opcode). This
  lets the macOS Metal renderer draw the prompt with identical cursor
  shapes, selection overlays, and styled spans as regular editor buffers.

  The prompt uses a reserved window_id (65534) that the Swift renderer
  recognizes for special positioning (bottom of the agent chat panel).

  Called from `Minga.Frontend.Emit.GUI` when the agent chat is visible.
  """

  alias Minga.Agent.UIState
  alias Minga.Agent.UIState.Panel
  alias Minga.Editor.SemanticWindow
  alias Minga.Editor.SemanticWindow.Selection
  alias Minga.Editor.SemanticWindow.Span
  alias Minga.Editor.SemanticWindow.VisualRow
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Input.Wrap, as: InputWrap
  alias Minga.UI.Theme

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Reserved window_id for the agent prompt SemanticWindow."
  @spec prompt_window_id() :: pos_integer()
  def prompt_window_id, do: 65_534

  @max_input_lines 8

  @doc """
  Builds a `SemanticWindow` for the agent prompt buffer.

  Returns `nil` when the agent chat is not visible or the prompt buffer
  is not available.

  The `inner_width` parameter is the number of text columns available
  inside the prompt box (excluding borders and padding). The caller
  computes this from the chat panel width.
  """
  @spec build(state(), pos_integer()) :: SemanticWindow.t() | nil
  def build(%EditorState{} = state, inner_width) when inner_width > 0 do
    panel = AgentAccess.panel(state)

    if is_pid(panel.prompt_buffer) do
      build_from_panel(state, panel, inner_width)
    end
  end

  def build(_, _), do: nil

  @doc """
  Returns the prompt height in visual rows (excluding borders).

  This is the number of rows of text content the prompt displays,
  clamped to `@max_input_lines`. Used by the emit stage to compute
  the total prompt area height for the GUI layout.
  """
  @spec visible_rows(Panel.t(), pos_integer()) :: pos_integer()
  def visible_rows(%Panel{} = panel, inner_width) do
    lines = Panel.input_lines(panel)
    total_visual = InputWrap.visual_line_count(lines, inner_width)
    max(min(total_visual, @max_input_lines), 1)
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec build_from_panel(state(), Panel.t(), pos_integer()) :: SemanticWindow.t()
  defp build_from_panel(state, panel, inner_width) do
    lines = Panel.input_lines(panel)
    cursor = Panel.input_cursor(panel)
    mode = Minga.Editing.mode(state)
    mode_state = Minga.Editor.Editing.mode_state(state)
    theme = state.theme
    at = Theme.agent_theme(theme)

    total_visual = InputWrap.visual_line_count(lines, inner_width)
    visible_count = max(min(total_visual, @max_input_lines), 1)

    # Compute scroll offset so the cursor is always visible
    {cursor_visual, cursor_visual_col} =
      InputWrap.logical_to_visual(lines, inner_width, cursor)

    scroll = InputWrap.scroll_offset(cursor_visual, visible_count, total_visual)

    # Build wrapped visual lines
    wrapped = InputWrap.wrap_lines(lines, inner_width)

    visual_rows =
      wrapped
      |> Enum.drop(scroll)
      |> Enum.take(visible_count)
      |> Enum.map(fn {logical_idx, vl} ->
        line_text = Enum.at(lines, logical_idx)
        build_visual_row(vl, line_text, logical_idx, panel, at, inner_width)
      end)

    # Cursor position relative to the visible window
    display_cursor_row = cursor_visual - scroll
    display_cursor_col = cursor_visual_col

    cursor_shape = cursor_shape_for_mode(mode)

    # Selection overlay
    selection = build_selection(mode, mode_state, cursor, scroll, inner_width, lines)

    %SemanticWindow{
      window_id: prompt_window_id(),
      rows: visual_rows,
      cursor_row: max(display_cursor_row, 0),
      cursor_col: max(display_cursor_col, 0),
      cursor_shape: cursor_shape,
      cursor_visible: panel.input_focused,
      selection: selection,
      search_matches: [],
      diagnostic_ranges: [],
      document_highlights: [],
      annotations: [],
      full_refresh: true
    }
  end

  @spec build_visual_row(
          InputWrap.visual_line(),
          String.t(),
          non_neg_integer(),
          Panel.t(),
          Theme.Agent.t(),
          pos_integer()
        ) :: VisualRow.t()
  defp build_visual_row(vl, line_text, _logical_idx, panel, at, inner_width) do
    {display_text, fg_color} =
      if UIState.paste_placeholder?(line_text) and vl.col_offset == 0 do
        case UIState.paste_block_index(line_text) do
          nil ->
            {vl.text, rgb_to_int(at.text_fg)}

          block_index ->
            line_count = paste_block_line_count(panel.pasted_blocks, block_index)
            indicator = "󰆏 [pasted #{line_count} lines]"
            text = String.slice(indicator, 0, inner_width)
            {text, rgb_to_int(at.hint_fg)}
        end
      else
        {vl.text, rgb_to_int(at.text_fg)}
      end

    # Build a single span covering the entire text with the appropriate color
    text_width = String.length(display_text)

    spans =
      if text_width > 0 do
        [
          %Span{
            start_col: 0,
            end_col: text_width,
            fg: fg_color,
            bg: rgb_to_int(at.input_bg),
            attrs: 0,
            font_weight: 0,
            font_id: 0
          }
        ]
      else
        []
      end

    %VisualRow{
      row_type: :normal,
      buf_line: 0,
      text: display_text,
      spans: spans,
      content_hash: VisualRow.compute_hash(display_text, spans)
    }
  end

  @spec build_selection(
          atom(),
          term(),
          {non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          pos_integer(),
          [String.t()]
        ) ::
          Selection.t() | nil
  defp build_selection(mode, mode_state, cursor, scroll, inner_width, lines)
       when mode in [:visual, :visual_line] do
    visual_start = Map.get(mode_state, :visual_start)

    case visual_start do
      {vl, vc} when is_integer(vl) ->
        {from, to} = if {vl, vc} <= cursor, do: {{vl, vc}, cursor}, else: {cursor, {vl, vc}}

        {from, to} =
          if mode == :visual_line do
            {from_line, _} = from
            {to_line, _} = to
            {{from_line, 0}, {to_line, 999_999}}
          else
            {from, to}
          end

        # Convert logical selection to visual coordinates
        {from_line, from_col} = from
        {to_line, to_col} = to

        {from_vis_row, from_vis_col} =
          InputWrap.logical_to_visual(lines, inner_width, {from_line, from_col})

        {to_vis_row, to_vis_col} =
          InputWrap.logical_to_visual(lines, inner_width, {to_line, to_col})

        # Adjust for scroll
        from_display_row = from_vis_row - scroll
        to_display_row = to_vis_row - scroll

        sel_type = if mode == :visual_line, do: :line, else: :char

        %Selection{
          type: sel_type,
          start_row: max(from_display_row, 0),
          start_col: from_vis_col,
          end_row: max(to_display_row, 0),
          end_col: to_vis_col
        }

      _ ->
        nil
    end
  end

  defp build_selection(_, _, _, _, _, _), do: nil

  @spec cursor_shape_for_mode(atom()) :: SemanticWindow.cursor_shape()
  defp cursor_shape_for_mode(:insert), do: :beam
  defp cursor_shape_for_mode(:normal), do: :block
  defp cursor_shape_for_mode(:visual), do: :block
  defp cursor_shape_for_mode(:visual_line), do: :block
  defp cursor_shape_for_mode(:operator_pending), do: :underline
  defp cursor_shape_for_mode(_), do: :block

  @spec paste_block_line_count([UIState.paste_block()], non_neg_integer()) :: non_neg_integer()
  defp paste_block_line_count(blocks, index) do
    case Enum.at(blocks, index) do
      %{text: text} -> text |> String.split("\n") |> length()
      nil -> 0
    end
  end

  # Convert a theme color integer to a 24-bit RGB integer.
  @spec rgb_to_int(non_neg_integer()) :: non_neg_integer()
  defp rgb_to_int(color), do: color
end
