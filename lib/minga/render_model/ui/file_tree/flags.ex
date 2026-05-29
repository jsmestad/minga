defmodule Minga.RenderModel.UI.FileTree.Flags do
  @moduledoc false

  @type t :: %__MODULE__{
          directory?: boolean(),
          expanded?: boolean(),
          active?: boolean(),
          dirty?: boolean(),
          last_child?: boolean()
        }

  defstruct directory?: false,
            expanded?: false,
            active?: false,
            dirty?: false,
            last_child?: false
end
