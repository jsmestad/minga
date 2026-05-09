defmodule MingaAgent.OutputStyle do
  @moduledoc """
  A discovered output style file.

  Output styles are session-scoped prompt fragments. The selected style's body is prepended to the native provider system prompt so users can shape the agent's response style without changing project instructions or the base system prompt.
  """

  @enforce_keys [:name, :body, :path, :source]
  defstruct [:name, :body, :path, :source]

  @typedoc "Where an output style file was discovered."
  @type source :: :global | :project

  @typedoc "A discovered output style."
  @type t :: %__MODULE__{
          name: String.t(),
          body: String.t(),
          path: String.t(),
          source: source()
        }
end
