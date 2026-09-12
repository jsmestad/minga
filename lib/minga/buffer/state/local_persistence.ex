defmodule Minga.Buffer.State.LocalPersistence do
  @moduledoc "Buffer-owned configuration for the local persistence boundary."

  @type t :: %__MODULE__{
          file_system: module() | nil,
          file_system_options: keyword()
        }

  defstruct file_system: nil,
            file_system_options: []

  @doc "Builds local persistence configuration from Buffer start options."
  @spec new(keyword(), module()) :: t()
  def new(opts, default_file_system) when is_list(opts) and is_atom(default_file_system) do
    %__MODULE__{
      file_system: Keyword.get(opts, :persistence_file_system, default_file_system),
      file_system_options: Keyword.get(opts, :persistence_file_system_options, [])
    }
  end
end
