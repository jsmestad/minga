defmodule Minga.Input.Picker do
  @moduledoc """
  Input handler for the fuzzy picker overlay.

  When a picker is active, all keys route to the picker UI. Commands
  returned by the picker (e.g., open file, switch buffer) are dispatched
  through the editor's command system. Mouse clicks on picker candidates
  select and confirm them; scroll wheel scrolls the candidate list.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Picker, as: PickerData

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{picker_ui: %{picker: picker}} = state, codepoint, modifiers)
      when is_struct(picker, PickerData) do
    new_state =
      case PickerUI.handle_key(state, codepoint, modifiers) do
        {s, {:execute_command, cmd}} -> Minga.Editor.dispatch_command(s, cmd)
        s -> s
      end

    {:handled, new_state}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  @impl true
  @spec handle_mouse(
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: Minga.Input.Handler.result()

  # Picker active: intercept scroll and clicks
  def handle_mouse(
        %{picker_ui: %{picker: %PickerData{} = picker, source: source}} = state,
        row,
        _col,
        button,
        _mods,
        :press,
        _cc
      ) do
    case button do
      :wheel_down ->
        new_picker = PickerData.move_down(picker)
        {:handled, put_in(state.picker_ui.picker, new_picker)}

      :wheel_up ->
        new_picker = PickerData.move_up(picker)
        {:handled, put_in(state.picker_ui.picker, new_picker)}

      :left ->
        {:handled, handle_picker_click(state, picker, source, row)}

      _ ->
        {:handled, state}
    end
  end

  # Picker not active: pass through
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _cc) do
    {:passthrough, state}
  end

  # ── Picker click helper ─────────────────────────────────────────────────

  @spec handle_picker_click(EditorState.t(), PickerData.t(), module(), integer()) ::
          EditorState.t()
  defp handle_picker_click(state, picker, source, row) do
    # Items grow upward from prompt_row - 1. Prompt is at viewport.rows - 1.
    {visible, _selected_offset} = PickerData.visible_items(picker)
    item_count = length(visible)
    prompt_row = state.viewport.rows - 1
    first_item_row = prompt_row - item_count

    clicked_idx = row - first_item_row

    case Enum.at(visible, clicked_idx) do
      nil ->
        state

      item ->
        new_state = PickerUI.close(state)
        new_state = source.on_select(item, new_state)

        case Map.get(new_state, :pending_command) do
          nil -> new_state
          cmd -> Minga.Editor.dispatch_command(Map.delete(new_state, :pending_command), cmd)
        end
    end
  end
end
