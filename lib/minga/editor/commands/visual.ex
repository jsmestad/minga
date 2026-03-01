defmodule Minga.Editor.Commands.Visual do
  @moduledoc """
  Visual selection commands: delete, yank, and wrap (auto-pair) the current
  visual selection.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode
  alias Minga.Mode.VisualState

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  def execute(%{buffer: buf, mode_state: %VisualState{} = ms} = state, :delete_visual_selection) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type
    cursor = BufferServer.cursor(buf)

    yanked =
      case visual_type do
        :char ->
          text = BufferServer.get_range(buf, anchor, cursor)
          BufferServer.delete_range(buf, anchor, cursor)
          text

        :line ->
          {anchor_line, _} = anchor
          {cursor_line, _} = cursor
          start_line = min(anchor_line, cursor_line)
          end_line = max(anchor_line, cursor_line)
          text = BufferServer.get_lines_content(buf, start_line, end_line)
          BufferServer.delete_lines(buf, start_line, end_line)
          text <> "\n"
      end

    Helpers.put_register(state, yanked, :delete)
  end

  def execute(%{buffer: buf, mode_state: %VisualState{} = ms} = state, :yank_visual_selection) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type
    cursor = BufferServer.cursor(buf)

    yanked =
      case visual_type do
        :char ->
          BufferServer.get_range(buf, anchor, cursor)

        :line ->
          {anchor_line, _} = anchor
          {cursor_line, _} = cursor
          start_line = min(anchor_line, cursor_line)
          end_line = max(anchor_line, cursor_line)
          BufferServer.get_lines_content(buf, start_line, end_line) <> "\n"
      end

    Helpers.put_register(state, yanked, :yank)
  end

  def execute(
        %{buffer: buf, mode_state: %VisualState{} = ms} = state,
        {:wrap_visual_selection, open, close}
      ) do
    anchor = ms.visual_anchor
    cursor = BufferServer.cursor(buf)
    {start_pos, end_pos} = Helpers.sort_positions(anchor, cursor)
    {end_line, end_col} = end_pos
    {start_line, start_col} = start_pos

    BufferServer.move_to(buf, {end_line, end_col + 1})
    BufferServer.insert_char(buf, close)
    BufferServer.move_to(buf, {start_line, start_col})
    BufferServer.insert_char(buf, open)
    BufferServer.move_to(buf, {start_line, start_col})
    state
  end
end
