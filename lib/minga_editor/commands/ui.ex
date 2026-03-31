defmodule MingaEditor.Commands.UI do
  @moduledoc """
  General UI commands: command palette, file finder, theme picker,
  parser restart, and other picker-based commands that don't belong
  to a specific domain.
  """

  @behaviour Minga.Command.Provider

  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias Minga.Parser.Manager, as: ParserManager

  @impl Minga.Command.Provider
  def __commands__ do
    [
      %Minga.Command{
        name: :command_palette,
        description: "Execute command",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.CommandSource) end
      },
      %Minga.Command{
        name: :find_file,
        description: "Find file in project",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.FileSource) end
      },
      %Minga.Command{
        name: :find_file_other_window,
        description: "Find file in other window",
        requires_buffer: false,
        execute: fn state ->
          state
          |> MingaEditor.Commands.Movement.execute(:split_vertical)
          |> PickerUI.open(MingaEditor.UI.Picker.FileSource)
        end
      },
      %Minga.Command{
        name: :theme_picker,
        description: "Pick theme",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.ThemeSource) end
      },
      %Minga.Command{
        name: :set_language,
        description: "Set buffer language",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.LanguageSource) end
      },
      %Minga.Command{
        name: :diagnostics_list,
        description: "List buffer diagnostics",
        requires_buffer: true,
        execute: fn state -> PickerUI.open(state, Minga.Diagnostics.PickerSource) end
      },
      %Minga.Command{
        name: :filetype_menu,
        description: "Show filetype actions",
        requires_buffer: true,
        execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.LanguageSource) end
      },
      %Minga.Command{
        name: :parser_restart,
        description: "Restart tree-sitter parser",
        requires_buffer: false,
        execute: &execute_parser_restart/1
      },
      %Minga.Command{
        name: :toggle_bottom_panel,
        description: "Toggle bottom panel",
        requires_buffer: false,
        execute: &toggle_bottom_panel/1
      },
      %Minga.Command{
        name: :bottom_panel_next_tab,
        description: "Bottom panel: next tab",
        requires_buffer: false,
        execute: &bottom_panel_next_tab/1
      },
      %Minga.Command{
        name: :bottom_panel_prev_tab,
        description: "Bottom panel: previous tab",
        requires_buffer: false,
        execute: &bottom_panel_prev_tab/1
      },
      %Minga.Command{
        name: :toggle_board,
        description: "Toggle The Board view",
        requires_buffer: false,
        execute: &toggle_board/1
      }
    ]
  end

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
    # Stash Board state so we can restore it when toggling back
    board_state = state.shell_state

    traditional_state = %MingaEditor.Shell.Traditional.State{
      suppress_tool_prompts: board_state.suppress_tool_prompts
    }

    %{
      state
      | shell: MingaEditor.Shell.Traditional,
        shell_state: traditional_state,
        layout: nil,
        stashed_board_state: board_state
    }
  end

  defp toggle_board(state) do
    # Restore stashed Board state, or create fresh if none
    board_state = Map.get(state, :stashed_board_state) || MingaEditor.Shell.Board.init()

    %{
      state
      | shell: MingaEditor.Shell.Board,
        shell_state: board_state,
        layout: nil,
        stashed_board_state: nil
    }
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
