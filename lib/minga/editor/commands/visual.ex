defmodule Minga.Editor.Commands.Visual do
  @moduledoc """
  Visual selection commands: delete, yank, and wrap (auto-pair) the current
  visual selection.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode
  alias Minga.Mode.VisualState

  @type state :: EditorState.t()

  @command_specs [
    {:delete_visual_selection, "Delete visual selection", true},
    {:yank_visual_selection, "Yank visual selection", true},
    {:select_all, "Select all", true}
  ]

  @spec execute(state(), Mode.command()) :: state()

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{mode_state: %VisualState{} = ms}}} =
          state,
        :delete_visual_selection
      ) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type
    cursor = Buffer.cursor(buf)

    {yanked, reg_type} =
      case visual_type do
        :char ->
          text = Buffer.text_between_inclusive(buf, anchor, cursor)
          Buffer.delete_range(buf, anchor, cursor)
          {text, :charwise}

        :line ->
          {anchor_line, _} = anchor
          {cursor_line, _} = cursor
          start_line = min(anchor_line, cursor_line)
          end_line = max(anchor_line, cursor_line)
          text = Buffer.lines_content(buf, start_line, end_line)
          Buffer.delete_lines(buf, start_line, end_line)
          {text <> "\n", :linewise}
      end

    state = Helpers.put_register(state, yanked, :delete, reg_type)
    if agent_chat_window?(state), do: Minga.Clipboard.write(yanked)
    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{mode_state: %VisualState{} = ms}}} =
          state,
        :yank_visual_selection
      ) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type
    cursor = Buffer.cursor(buf)

    {yanked, reg_type} =
      case visual_type do
        :char ->
          {Buffer.text_between_inclusive(buf, anchor, cursor), :charwise}

        :line ->
          {anchor_line, _} = anchor
          {cursor_line, _} = cursor
          start_line = min(anchor_line, cursor_line)
          end_line = max(anchor_line, cursor_line)
          {Buffer.lines_content(buf, start_line, end_line) <> "\n", :linewise}
      end

    state = Helpers.put_register(state, yanked, :yank, reg_type)

    # Auto-copy to system clipboard when yanking from the agent chat buffer,
    # since the primary use case is copying text out of the chat.
    if agent_chat_window?(state), do: Minga.Clipboard.write(yanked)

    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{mode_state: %VisualState{} = ms}}} =
          state,
        {:wrap_visual_selection, open, close}
      ) do
    anchor = ms.visual_anchor
    cursor = Buffer.cursor(buf)
    {start_pos, end_pos} = Helpers.sort_positions(anchor, cursor)
    {end_line, end_col} = end_pos
    {start_line, start_col} = start_pos

    Buffer.move_to(buf, {end_line, end_col + 1})
    Buffer.insert_char(buf, close)
    Buffer.move_to(buf, {start_line, start_col})
    Buffer.insert_char(buf, open)
    Buffer.move_to(buf, {start_line, start_col})
    state
  end

  def execute(
        %{
          workspace: %{buffers: %{active: buf}, editing: %{mode_state: %VisualState{} = ms} = vim}
        } =
          state,
        {:visual_text_object, modifier, spec}
      ) do
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)
    buffer_id = HighlightSync.buffer_id_for(state, buf)
    range = Helpers.compute_text_object_range(gb, cursor, modifier, spec, buffer_id)

    case range do
      nil ->
        state

      {start_pos, end_pos} ->
        # Update visual anchor to start of text object, move cursor to end
        new_ms = %{ms | visual_anchor: start_pos}
        Buffer.move_to(buf, end_pos)
        %{state | workspace: %{state.workspace | editing: %{vim | mode_state: new_ms}}}
    end
  end

  # ── Select all ─────────────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :select_all) when is_pid(buf) do
    line_count = Buffer.line_count(buf)
    last_line = max(line_count - 1, 0)

    last_col =
      case Buffer.lines(buf, last_line, 1) do
        [text] -> max(byte_size(text) - 1, 0)
        _ -> 0
      end

    # Enter visual line mode with anchor at start, cursor at end
    Buffer.move_to(buf, {last_line, last_col})

    visual_state = %VisualState{
      visual_anchor: {0, 0},
      visual_type: :line
    }

    EditorState.transition_mode(state, :visual, visual_state)
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

  # Checks if the active window is an agent chat window by inspecting
  # the window's content field (structural check, no GenServer call).
  defp agent_chat_window?(state) do
    case EditorState.active_window_struct(state) do
      %{content: {:agent_chat, _}} -> true
      _ -> false
    end
  end
end
