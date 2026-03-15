defmodule Minga.Editor.Commands.Visual do
  @moduledoc """
  Visual selection commands: delete, yank, and wrap (auto-pair) the current
  visual selection.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode
  alias Minga.Mode.VisualState

  @type state :: EditorState.t()

  @command_specs [
    {:delete_visual_selection, "Delete visual selection", true},
    {:yank_visual_selection, "Yank visual selection", true}
  ]

  @spec execute(state(), Mode.command()) :: state()

  def execute(
        %{buffers: %{active: buf}, vim: %{mode_state: %VisualState{} = ms}} = state,
        :delete_visual_selection
      ) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type
    cursor = BufferServer.cursor(buf)

    {yanked, reg_type} =
      case visual_type do
        :char ->
          text = BufferServer.get_range(buf, anchor, cursor)
          BufferServer.delete_range(buf, anchor, cursor)
          {text, :charwise}

        :line ->
          {anchor_line, _} = anchor
          {cursor_line, _} = cursor
          start_line = min(anchor_line, cursor_line)
          end_line = max(anchor_line, cursor_line)
          text = BufferServer.get_lines_content(buf, start_line, end_line)
          BufferServer.delete_lines(buf, start_line, end_line)
          {text <> "\n", :linewise}
      end

    Helpers.put_register(state, yanked, :delete, reg_type)
  end

  def execute(
        %{buffers: %{active: buf}, vim: %{mode_state: %VisualState{} = ms}} = state,
        :yank_visual_selection
      ) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type
    cursor = BufferServer.cursor(buf)

    {yanked, reg_type} =
      case visual_type do
        :char ->
          {BufferServer.get_range(buf, anchor, cursor), :charwise}

        :line ->
          {anchor_line, _} = anchor
          {cursor_line, _} = cursor
          start_line = min(anchor_line, cursor_line)
          end_line = max(anchor_line, cursor_line)
          {BufferServer.get_lines_content(buf, start_line, end_line) <> "\n", :linewise}
      end

    Helpers.put_register(state, yanked, :yank, reg_type)
  end

  def execute(
        %{buffers: %{active: buf}, vim: %{mode_state: %VisualState{} = ms}} = state,
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

  def execute(
        %{buffers: %{active: buf}, vim: %{mode_state: %VisualState{} = ms} = vim} = state,
        {:visual_text_object, modifier, spec}
      ) do
    gb = BufferServer.snapshot(buf)
    cursor = Document.cursor(gb)
    range = Helpers.compute_text_object_range(gb, cursor, modifier, spec)

    case range do
      nil ->
        state

      {start_pos, end_pos} ->
        # Update visual anchor to start of text object, move cursor to end
        new_ms = %{ms | visual_anchor: start_pos}
        BufferServer.move_to(buf, end_pos)
        %{state | vim: %{vim | mode_state: new_ms}}
    end
  end

  @impl Minga.Command.Provider
  def __commands__ do
    Enum.map(@command_specs, fn {name, desc, requires_buffer} ->
      %Minga.Command{
        name: name,
        description: desc,
        requires_buffer: requires_buffer,
        execute: fn state -> execute(state, name) end
      }
    end)
  end
end
