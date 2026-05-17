defmodule MingaEditor.Commands.UI do
  @moduledoc """
  General UI commands: command palette, file finder, theme picker,
  parser restart, and other picker-based commands that don't belong
  to a specific domain.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias Minga.Parser.Manager, as: ParserManager

  command(:command_palette, "Execute command",
    requires_buffer: false,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.CommandSource) end
  )

  command(:find_file, "Find file in project",
    requires_buffer: false,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.FileSource) end
  )

  command(:find_file_other_window, "Find file in other window",
    requires_buffer: false,
    execute: fn state ->
      state
      |> MingaEditor.Commands.Movement.execute(:split_vertical)
      |> PickerUI.open(MingaEditor.UI.Picker.FileSource)
    end
  )

  command(:theme_picker, "Pick theme",
    requires_buffer: false,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.ThemeSource) end
  )

  command(:set_language, "Set buffer language",
    requires_buffer: false,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.LanguageSource) end
  )

  command(:diagnostics_list, "List buffer diagnostics",
    requires_buffer: true,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.Sources.Diagnostics) end
  )

  command(:filetype_menu, "Show filetype actions",
    requires_buffer: true,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.LanguageSource) end
  )

  command(:parser_restart, "Restart tree-sitter parser",
    requires_buffer: false,
    execute: &execute_parser_restart/1
  )

  command(:toggle_bottom_panel, "Toggle bottom panel",
    requires_buffer: false,
    execute: &toggle_bottom_panel/1
  )

  command(:bottom_panel_next_tab, "Bottom panel: next tab",
    requires_buffer: false,
    execute: &bottom_panel_next_tab/1
  )

  command(:bottom_panel_prev_tab, "Bottom panel: previous tab",
    requires_buffer: false,
    execute: &bottom_panel_prev_tab/1
  )

  command(:toggle_board, "Toggle The Board view",
    requires_buffer: false,
    execute: &toggle_board/1
  )

  @spec toggle_bottom_panel(EditorState.t()) :: EditorState.t()
  defp toggle_bottom_panel(state), do: frontend(state).toggle_bottom_panel(state)

  @spec bottom_panel_next_tab(EditorState.t()) :: EditorState.t()
  defp bottom_panel_next_tab(state), do: frontend(state).bottom_panel_next_tab(state)

  @spec bottom_panel_prev_tab(EditorState.t()) :: EditorState.t()
  defp bottom_panel_prev_tab(state), do: frontend(state).bottom_panel_prev_tab(state)

  @spec frontend(EditorState.t()) :: module()
  defp frontend(%{capabilities: caps}) do
    if MingaEditor.Frontend.gui?(caps), do: __MODULE__.GUI, else: __MODULE__.TUI
  end

  @spec toggle_board(EditorState.t()) :: EditorState.t()
  defp toggle_board(%{shell: MingaEditor.Shell.Board} = state) do
    board_state = state.shell_state

    EditorState.switch_from_board_to_traditional(
      state,
      board_state,
      board_state.suppress_tool_prompts
    )
  end

  defp toggle_board(state) do
    board_state = Map.get(state, :stashed_board_state) || MingaEditor.Shell.Board.init()
    EditorState.switch_to_board(state, board_state)
  end

  @spec execute_parser_restart(EditorState.t()) :: EditorState.t()
  defp execute_parser_restart(state) do
    case ParserManager.restart() do
      :ok ->
        EditorState.set_status(state, "Parser restarted")
        |> then(&%{&1 | parser_status: :available})

      {:error, :binary_not_found} ->
        EditorState.set_status(state, "Parser restart failed: binary not found")
        |> then(&%{&1 | parser_status: :unavailable})
    end
  catch
    :exit, _ ->
      EditorState.set_status(state, "Parser restart failed: manager not available")
  end
end
