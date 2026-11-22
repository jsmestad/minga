defmodule MingaEditor.Extension.Picker do
  @moduledoc "Opens source-owned pickers from extension editor callbacks."

  alias Minga.Extension.InvocationContext
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.PickerUI

  @doc "Opens a source implementing `MingaEditor.Extension.Picker.Source` with immutable callback arguments."
  @spec open(EditorAPI.state(), module(), term()) :: EditorAPI.state()
  def open(state, source_module, args) when is_atom(source_module) do
    case InvocationContext.current_source() do
      {:ok, source} ->
        PickerUI.open_extension(state, source_module, source, args)

      :none ->
        raise ArgumentError, "extension pickers must be opened from an admitted editor callback"
    end
  end
end
