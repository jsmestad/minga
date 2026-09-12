defmodule MingaEditor.Effects.ExternalFormatResult do
  @moduledoc "Typed external formatter worker result awaiting atomic buffer application."

  @enforce_keys [:buffer, :version, :content, :diagnostics]
  defstruct [:buffer, :version, :content, :diagnostics, file_name: "scratch"]

  @type t :: %__MODULE__{
          buffer: pid(),
          version: non_neg_integer(),
          content: String.t(),
          diagnostics: String.t(),
          file_name: String.t()
        }

  @doc "Builds a formatter result tied to the buffer version that was formatted."
  @spec new(pid(), non_neg_integer(), String.t()) :: t()
  def new(buffer, version, content), do: new(buffer, version, content, "scratch", "")

  @doc "Builds a formatter result with display metadata captured by the worker."
  @spec new(pid(), non_neg_integer(), String.t(), String.t()) :: t()
  def new(buffer, version, content, file_name), do: new(buffer, version, content, file_name, "")

  @doc "Builds a formatter result with display metadata and separate diagnostics."
  @spec new(pid(), non_neg_integer(), String.t(), String.t(), String.t()) :: t()
  def new(buffer, version, content, file_name, diagnostics)
      when is_pid(buffer) and is_integer(version) and version >= 0 and is_binary(content) and
             is_binary(file_name) and is_binary(diagnostics) do
    %__MODULE__{
      buffer: buffer,
      version: version,
      content: content,
      diagnostics: diagnostics,
      file_name: file_name
    }
  end
end
