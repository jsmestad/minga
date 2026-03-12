defmodule Minga.Editor.RenderPipeline.ComposeHelpers do
  @moduledoc """
  Helper functions for the Compose stage of the render pipeline.

  Injects modeline draws into window frames, resolves cursor position
  and shape, and handles agent panel cursor overrides.

  Extracted from `RenderPipeline` to reduce module size.
  """

  alias Minga.Agent.PanelState
  alias Minga.Buffer.Unicode
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Overlay, WindowFrame}
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline.ChromeHelpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Port.Protocol

  @type state :: EditorState.t()

  # Agent input area = 3 rows (border + text + padding); cursor goes on the text row.
  @agent_input_height 3

  # ── Modeline injection ─────────────────────────────────────────────────────

  @doc """
  Merges modeline draws into a WindowFrame, applying grayscale dimming
  for inactive windows (cursor == nil means inactive).
  """
  @spec inject_modeline(WindowFrame.t(), %{non_neg_integer() => [DisplayList.draw()]}) ::
          WindowFrame.t()
  def inject_modeline(wf, modeline_map) do
    is_active = wf.cursor != nil
    all_draws = Enum.flat_map(modeline_map, fn {_id, draws} -> draws end)

    dimmed =
      if is_active do
        all_draws
      else
        DisplayList.grayscale_draws(all_draws)
      end

    %{wf | modeline: DisplayList.draws_to_layer(dimmed)}
  end

  # ── Cursor resolution ─────────────────────────────────────────────────────

  @doc "Resolves the final cursor position from mode state or buffer position."
  @spec resolve_cursor(
          state(),
          {non_neg_integer(), non_neg_integer()} | nil,
          non_neg_integer()
        ) :: {non_neg_integer(), non_neg_integer()}
  def resolve_cursor(
        %{mode: :search, mode_state: mode_state},
        _cursor_info,
        minibuffer_row
      ) do
    search_col = Unicode.display_width(mode_state.input) + 1
    {minibuffer_row, search_col}
  end

  def resolve_cursor(
        %{mode: :command, mode_state: mode_state},
        _cursor_info,
        minibuffer_row
      ) do
    cmd_col = Unicode.display_width(mode_state.input) + 1
    {minibuffer_row, cmd_col}
  end

  def resolve_cursor(
        %{mode: :eval, mode_state: mode_state},
        _cursor_info,
        minibuffer_row
      ) do
    eval_col = Unicode.display_width(mode_state.input) + 6
    {minibuffer_row, eval_col}
  end

  def resolve_cursor(_state, {row, col}, _minibuffer_row), do: {row, col}
  def resolve_cursor(_state, nil, _minibuffer_row), do: {0, 0}

  @doc "Finds a cursor position from picker overlays, if any."
  @spec find_picker_cursor([Overlay.t()]) :: {non_neg_integer(), non_neg_integer()} | nil
  def find_picker_cursor(overlays) do
    Enum.find_value(overlays, fn %Overlay{cursor: c} -> c end)
  end

  # ── Agent cursor override ─────────────────────────────────────────────────

  @doc "Overrides cursor position and shape when the agent panel input is focused."
  @spec agent_cursor_override_from_layout(
          state(),
          {non_neg_integer(), non_neg_integer()},
          atom(),
          Layout.t()
        ) ::
          {{non_neg_integer(), non_neg_integer()}, Protocol.cursor_shape()}
  def agent_cursor_override_from_layout(
        state,
        cursor,
        shape,
        %{agent_panel: {row, col, _w, h}} = _layout
      )
      when h > 0 do
    panel = AgentAccess.panel(state)

    if panel.visible and panel.input_focused do
      {cursor_line, cursor_col} = PanelState.input_cursor(panel)
      input_row = row + h - @agent_input_height + 1 + cursor_line
      input_col = col + 2 + cursor_col

      {{input_row, input_col}, ChromeHelpers.input_cursor_shape(panel)}
    else
      {cursor, shape}
    end
  end

  def agent_cursor_override_from_layout(_state, cursor, shape, _layout) do
    {cursor, shape}
  end
end
