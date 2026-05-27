defmodule MingaEditor.RenderModel.UI.ThemeBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Theme
  alias MingaEditor.UI.Theme, as: EditorTheme
  alias MingaEditor.UI.Theme.Slots

  @spec build(EditorTheme.t()) :: Theme.t()
  def build(%EditorTheme{} = theme) do
    slots =
      theme
      |> Slots.to_color_pairs()
      |> Enum.reject(fn {_slot, color} -> is_nil(color) end)

    %Theme{name: theme.name, color_slots: slots}
  end
end
