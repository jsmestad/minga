defmodule Minga.Editor.Commands.UI do
  @moduledoc """
  General UI commands: command palette, file finder, theme picker,
  parser restart, and other picker-based commands that don't belong
  to a specific domain.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Editor.BottomPanel
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Parser.Manager, as: ParserManager

  @impl Minga.Command.Provider
  def __commands__ do
    [
      %Minga.Command{
        name: :command_palette,
        description: "Execute command",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, Minga.Picker.CommandSource) end
      },
      %Minga.Command{
        name: :find_file,
        description: "Find file in project",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, Minga.Picker.FileSource) end
      },
      %Minga.Command{
        name: :theme_picker,
        description: "Pick theme",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, Minga.Picker.ThemeSource) end
      },
      %Minga.Command{
        name: :set_language,
        description: "Set buffer language",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, Minga.Picker.LanguageSource) end
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
        execute: fn state -> PickerUI.open(state, Minga.Picker.LanguageSource) end
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
      }
    ]
  end

  @spec toggle_bottom_panel(EditorState.t()) :: EditorState.t()
  defp toggle_bottom_panel(state) do
    %{state | bottom_panel: BottomPanel.toggle(state.bottom_panel)}
  end

  @spec bottom_panel_next_tab(EditorState.t()) :: EditorState.t()
  defp bottom_panel_next_tab(state) do
    %{state | bottom_panel: BottomPanel.next_tab(state.bottom_panel)}
  end

  @spec bottom_panel_prev_tab(EditorState.t()) :: EditorState.t()
  defp bottom_panel_prev_tab(state) do
    %{state | bottom_panel: BottomPanel.prev_tab(state.bottom_panel)}
  end

  @spec execute_parser_restart(EditorState.t()) :: EditorState.t()
  defp execute_parser_restart(state) do
    case ParserManager.restart() do
      :ok ->
        %{state | status_msg: "Parser restarted", parser_status: :available}

      {:error, :binary_not_found} ->
        %{
          state
          | status_msg: "Parser restart failed: binary not found",
            parser_status: :unavailable
        }
    end
  catch
    :exit, _ ->
      %{state | status_msg: "Parser restart failed: manager not available"}
  end
end
