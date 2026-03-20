defmodule Minga.Editor.RenderPipeline.ComposeHelpers do
  @moduledoc """
  Helper functions for the Compose stage of the render pipeline.

  Injects modeline draws into window frames, resolves cursor position
  and shape, and handles agent panel cursor overrides.

  Extracted from `RenderPipeline` to reduce module size.
  """

  alias Minga.Agent.UIState
  alias Minga.Buffer.Unicode
  alias Minga.Editor.DisplayList.{Cursor, Overlay}
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline.ChromeHelpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess

  @type state :: EditorState.t()

  # Agent input area = 3 rows (border + text + padding); cursor goes on the text row.
  @agent_input_height 3

  # ── Cursor resolution ─────────────────────────────────────────────────────

  @doc "Resolves the final cursor position from mode state or buffer position."
  @spec resolve_cursor(
          state(),
          Cursor.t() | nil,
          non_neg_integer()
        ) :: {non_neg_integer(), non_neg_integer()}
  def resolve_cursor(
        %{vim: %{mode: :search, mode_state: mode_state}},
        _cursor_info,
        minibuffer_row
      ) do
    search_col = Unicode.display_width(mode_state.input) + 1
    {minibuffer_row, search_col}
  end

  def resolve_cursor(
        %{vim: %{mode: :command, mode_state: mode_state}},
        _cursor_info,
        minibuffer_row
      ) do
    cmd_col = Unicode.display_width(mode_state.input) + 1
    {minibuffer_row, cmd_col}
  end

  def resolve_cursor(
        %{vim: %{mode: :eval, mode_state: mode_state}},
        _cursor_info,
        minibuffer_row
      ) do
    eval_col = Unicode.display_width(mode_state.input) + 6
    {minibuffer_row, eval_col}
  end

  def resolve_cursor(_state, %Cursor{row: row, col: col}, _minibuffer_row), do: {row, col}
  def resolve_cursor(_state, nil, _minibuffer_row), do: {0, 0}

  @doc "Finds a cursor position from picker overlays, if any."
  @spec find_picker_cursor([Overlay.t()]) :: {non_neg_integer(), non_neg_integer()} | nil
  def find_picker_cursor(overlays) do
    Enum.find_value(overlays, fn %Overlay{cursor: c} -> c end)
  end

  # ── Agent cursor ────────────────────────────────────────────────────────────

  @doc """
  Returns a Cursor for the agent panel (bottom panel) input if focused.

  Returns nil when the agent panel isn't visible, doesn't have focus,
  or doesn't exist in the layout.
  """
  @spec agent_cursor_from_layout(state(), Layout.t()) :: Cursor.t() | nil
  def agent_cursor_from_layout(
        state,
        %{agent_panel: {row, col, _w, h}}
      )
      when h > 0 do
    panel = AgentAccess.panel(state)

    if panel.visible and panel.input_focused do
      {cursor_line, cursor_col} = UIState.input_cursor(panel)
      input_row = row + h - @agent_input_height + 1 + cursor_line
      input_col = col + 2 + cursor_col

      Cursor.new(input_row, input_col, ChromeHelpers.input_cursor_shape(state.vim.mode))
    else
      nil
    end
  end

  def agent_cursor_from_layout(_state, _layout), do: nil
end
