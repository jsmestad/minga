defmodule MingaEditor.Effects.ExternalFormatResult do
  @moduledoc "Typed external formatter worker result awaiting atomic buffer application."

  @enforce_keys [:buffer, :version, :content]
  defstruct [:buffer, :version, :content]

  @type t :: %__MODULE__{
          buffer: pid(),
          version: non_neg_integer(),
          content: String.t()
        }

  @doc "Builds a formatter result tied to the buffer version that was formatted."
  @spec new(pid(), non_neg_integer(), String.t()) :: t()
  def new(buffer, version, content)
      when is_pid(buffer) and is_integer(version) and version >= 0 and is_binary(content) do
    %__MODULE__{buffer: buffer, version: version, content: content}
  end
end
