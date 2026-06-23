defmodule Minga.RenderModel.UI.AgentContext.Todo do
  @moduledoc false

  @type status :: :pending | :in_progress | :done

  @type t :: %__MODULE__{
          status: status(),
          description: String.t()
        }

  @enforce_keys [:description]
  defstruct [:description, status: :pending]
end
