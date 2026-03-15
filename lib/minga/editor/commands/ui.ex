defmodule Minga.Editor.Commands.UI do
  @moduledoc """
  General UI commands: command palette, file finder, theme picker, and
  other picker-based commands that don't belong to a specific domain.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Editor.PickerUI

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
      }
    ]
  end
end
