defmodule Minga.RenderModel.UI.FileTree.Editing do
  @moduledoc false

  @type editing_type :: :new_file | :new_folder | :rename

  @type t :: %__MODULE__{
          type: editing_type(),
          text: String.t()
        }

  @enforce_keys [:type, :text]
  defstruct [:type, :text]
end
