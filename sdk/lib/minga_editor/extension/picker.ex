defmodule MingaEditor.Extension.Picker do
  @moduledoc "Opens source-owned pickers from extension editor callbacks."

  alias MingaEditor.Extension.EditorAPI

  @doc "Opens a source implementing `MingaEditor.Extension.Picker.Source` with immutable callback arguments."
  @spec open(EditorAPI.state(), module(), term()) :: EditorAPI.state()
  def open(_state, _source_module, _args), do: raise("minga_sdk is compile-time only")
end
