defmodule Minga.LSP.ServerConfig do
  @moduledoc "Configuration for a single language server."

  @enforce_keys [:name, :command]
  defstruct name: nil,
            command: nil,
            args: [],
            root_markers: [],
            init_options: %{}

  @type t :: %__MODULE__{
          name: atom(),
          command: String.t(),
          args: [String.t()],
          root_markers: [String.t()],
          init_options: map()
        }
end
