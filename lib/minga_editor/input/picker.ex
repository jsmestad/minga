defmodule MingaEditor.Input.Picker do
  @moduledoc """
  Input handler for the fuzzy picker overlay.

  When a picker is active, all keys route to the picker UI. Commands
  returned by the picker (e.g., open file, switch buffer) are dispatched
  through the editor's command system. Mouse clicks on picker candidates
  select and confirm them; scroll wheel scrolls the candidate list.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.FocusTree
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.UI.Picker, as: PickerData

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, codepoint, modifiers) do
    case ModalOverlay.match(state.shell_state.modal, :picker) do
      true ->
        new_state =
          case PickerUI.handle_key(state, codepoint, modifiers) do
            {s, {:execute_command, cmd}} -> MingaEditor.dispatch_command(s, cmd)
            s -> s
          end

        {:handled, new_state}

      false ->
        {:passthrough, state}
    end
  end

  @impl true
  @spec handle_mouse(
          state(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()

  def handle_mouse(state, row, col, button, mods, event_type, click_count) do
    case routed_picker_node(state, row, col, button) do
      %FocusNode{} = node ->
        handle_mouse_at_node(state, node, row, col, button, mods, event_type, click_count)

      nil ->
        {:passthrough, state}
    end
  end

  @impl true
  @spec handle_mouse_at_node(
          state(),
          FocusNode.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()

  # Picker active: intercept scroll and clicks routed by the focus tree.
  def handle_mouse_at_node(
        %{
          shell_state: %{
            modal: {:picker, %{picker_ui: %{picker: %PickerData{} = picker, source: source}}}
          }
        } = state,
        %FocusNode{} = node,
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
        {:handled, PickerUI.update_picker(state, &%{&1 | picker: new_picker})}

      :wheel_up ->
        new_picker = PickerData.move_up(picker)
        {:handled, PickerUI.update_picker(state, &%{&1 | picker: new_picker})}

      :left ->
        {:handled, handle_picker_left_click(state, node, picker, source, row)}

      _ ->
        {:handled, state}
    end
  end

  def handle_mouse_at_node(state, _node, _row, _col, _button, _mods, _event_type, _cc) do
    {:passthrough, state}
  end

  # ── Picker click helpers ────────────────────────────────────────────────

  @spec routed_picker_node(EditorState.t(), integer(), integer(), atom()) :: FocusNode.t() | nil
  defp routed_picker_node(state, row, col, button) do
    tree = FocusTree.from_state(state)

    path =
      if button in [:wheel_down, :wheel_up],
        do: FocusTree.scroll_path(tree, row, col),
        else: FocusTree.hit_path(tree, row, col)

    Enum.find(path, &(&1.handler == __MODULE__))
  end

  @spec handle_picker_left_click(
          EditorState.t(),
          FocusNode.t(),
          PickerData.t(),
          module(),
          integer()
        ) ::
          EditorState.t()
  defp handle_picker_left_click(
         state,
         %FocusNode{content_type: :picker_backdrop},
         _picker,
         _source,
         _row
       ) do
    {:picker, %{picker_ui: %{layout: layout}}} = state.shell_state.modal

    case layout do
      :centered -> PickerUI.close(state)
      _bottom -> state
    end
  end

  defp handle_picker_left_click(state, %FocusNode{} = node, picker, source, row) do
    handle_picker_click(state, node, picker, source, row)
  end

  @spec handle_picker_click(EditorState.t(), FocusNode.t(), PickerData.t(), module(), integer()) ::
          EditorState.t()
  defp handle_picker_click(state, node, picker, source, row) do
    {:picker, %{picker_ui: %{layout: layout}}} = state.shell_state.modal

    case clicked_item(layout, state, node, picker, row) do
      nil -> state
      item -> confirm_clicked_item(state, source, item)
    end
  end

  @spec clicked_item(
          MingaEditor.UI.Picker.Source.layout(),
          EditorState.t(),
          FocusNode.t(),
          PickerData.t(),
          integer()
        ) :: PickerData.item() | nil
  defp clicked_item(layout, state, node, picker, row) do
    case click_index(layout, state, node, picker, row) do
      nil ->
        nil

      idx ->
        {visible, _selected_offset} = visible_items_for_click(layout, state, node, picker)
        Enum.at(visible, idx)
    end
  end

  @spec click_index(
          MingaEditor.UI.Picker.Source.layout(),
          EditorState.t(),
          FocusNode.t(),
          PickerData.t(),
          integer()
        ) :: non_neg_integer() | nil
  defp click_index(:centered, _state, node, _picker, row), do: centered_click_index(node, row)
  defp click_index(_bottom, state, _node, picker, row), do: bottom_click_index(state, picker, row)

  @spec confirm_clicked_item(EditorState.t(), module(), PickerData.item()) :: EditorState.t()
  defp confirm_clicked_item(state, source, item) do
    new_state = PickerUI.close(state)
    new_state = source.on_select(item, new_state)

    case Map.get(new_state, :pending_command) do
      nil ->
        new_state

      cmd ->
        record_command_execution(source, cmd)
        MingaEditor.dispatch_command(Map.delete(new_state, :pending_command), cmd)
    end
  end

  @spec record_command_execution(module(), term()) :: :ok
  defp record_command_execution(MingaEditor.UI.Picker.CommandSource, command_name)
       when is_atom(command_name) do
    Minga.Project.record_command(command_name)
  catch
    :exit, _ -> :ok
  end

  defp record_command_execution(_source, _command_name), do: :ok

  # Bottom-anchored: items grow upward from the prompt at viewport bottom.
  @spec bottom_click_index(EditorState.t(), PickerData.t(), integer()) :: non_neg_integer() | nil
  defp bottom_click_index(state, picker, row) do
    {visible, _} = PickerData.visible_items(picker, bottom_item_capacity(state))
    item_count = length(visible)
    prompt_row = state.terminal_viewport.rows - 1
    first_item_row = prompt_row - item_count
    clicked_idx = row - first_item_row

    if clicked_idx >= 0 and clicked_idx < item_count do
      clicked_idx
    else
      nil
    end
  end

  @spec visible_items_for_click(
          MingaEditor.UI.Picker.Source.layout(),
          EditorState.t(),
          FocusNode.t(),
          PickerData.t()
        ) :: {[PickerData.item()], non_neg_integer()}
  defp visible_items_for_click(:centered, _state, node, picker) do
    PickerData.visible_items(picker, centered_item_capacity(node))
  end

  defp visible_items_for_click(_bottom, state, _node, picker) do
    PickerData.visible_items(picker, bottom_item_capacity(state))
  end

  @spec bottom_item_capacity(EditorState.t()) :: pos_integer()
  defp bottom_item_capacity(state), do: max(state.terminal_viewport.rows - 3, 1)

  # Centered: items start at the top of the FloatingWindow interior.
  @spec centered_click_index(FocusNode.t(), integer()) :: non_neg_integer() | nil
  defp centered_click_index(%FocusNode{rect: {box_row, _box_col, _box_w, _box_h}} = node, row) do
    interior_row = box_row + 1
    item_rows = centered_item_capacity(node)
    clicked_idx = row - interior_row

    if clicked_idx >= 0 and clicked_idx < item_rows do
      clicked_idx
    else
      nil
    end
  end

  @spec centered_item_capacity(FocusNode.t()) :: non_neg_integer()
  defp centered_item_capacity(%FocusNode{rect: {_box_row, _box_col, _box_w, box_h}}) do
    max(box_h - 3, 0)
  end
end
