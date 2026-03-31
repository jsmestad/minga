defmodule MingaEditor.Agent.SlashCommand.Command do
  @moduledoc false
  @enforce_keys [:name, :description]
  defstruct [:name, :description]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t()
        }
end
