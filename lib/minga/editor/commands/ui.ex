defmodule Minga.Editor.Commands.UI do
  @moduledoc """
  General UI commands: command palette, file finder, theme picker,
  parser restart, and other picker-based commands that don't belong
  to a specific domain.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Parser.Manager, as: ParserManager
  alias Minga.Port.Capabilities

  @impl Minga.Command.Provider
  def __commands__ do
    [
      %Minga.Command{
        name: :command_palette,
        description: "Execute command",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, Minga.UI.Picker.CommandSource) end
      },
      %Minga.Command{
        name: :find_file,
        description: "Find file in project",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, Minga.UI.Picker.FileSource) end
      },
      %Minga.Command{
        name: :find_file_other_window,
        description: "Find file in other window",
        requires_buffer: false,
        execute: fn state ->
          state
          |> Minga.Editor.Commands.Movement.execute(:split_vertical)
          |> PickerUI.open(Minga.UI.Picker.FileSource)
        end
      },
      %Minga.Command{
        name: :theme_picker,
        description: "Pick theme",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, Minga.UI.Picker.ThemeSource) end
      },
      %Minga.Command{
        name: :set_language,
        description: "Set buffer language",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, Minga.UI.Picker.LanguageSource) end
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
        execute: fn state -> PickerUI.open(state, Minga.UI.Picker.LanguageSource) end
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
  defp toggle_bottom_panel(state), do: frontend(state).toggle_bottom_panel(state)

  @spec bottom_panel_next_tab(EditorState.t()) :: EditorState.t()
  defp bottom_panel_next_tab(state), do: frontend(state).bottom_panel_next_tab(state)

  @spec bottom_panel_prev_tab(EditorState.t()) :: EditorState.t()
  defp bottom_panel_prev_tab(state), do: frontend(state).bottom_panel_prev_tab(state)

  @spec frontend(EditorState.t()) :: module()
  defp frontend(%{capabilities: caps}) do
    if Capabilities.gui?(caps), do: __MODULE__.GUI, else: __MODULE__.TUI
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
