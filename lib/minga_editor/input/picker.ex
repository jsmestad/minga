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

    clicked_idx =
      case layout do
        :centered -> centered_click_index(node, row)
        _bottom -> bottom_click_index(state, picker, row)
      end

    {visible, _selected_offset} = PickerData.visible_items(picker)

    case Enum.at(visible, clicked_idx) do
      nil ->
        state

      item ->
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
  @spec bottom_click_index(EditorState.t(), PickerData.t(), integer()) :: integer()
  defp bottom_click_index(state, picker, row) do
    {visible, _} = PickerData.visible_items(picker)
    item_count = length(visible)
    prompt_row = state.terminal_viewport.rows - 1
    first_item_row = prompt_row - item_count
    row - first_item_row
  end

  # Centered: items start at the top of the FloatingWindow interior.
  @spec centered_click_index(FocusNode.t(), integer()) :: integer()
  defp centered_click_index(%FocusNode{rect: {box_row, _box_col, _box_w, _box_h}}, row) do
    interior_row = box_row + 1
    row - interior_row
  end
end
