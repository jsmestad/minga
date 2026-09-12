defmodule Minga.Editing.Formatter.Result do
  @moduledoc "External formatter output with document text and diagnostics kept separate."

  @enforce_keys [:content, :diagnostics]
  defstruct [:content, :diagnostics]

  @type t :: %__MODULE__{
          content: String.t(),
          diagnostics: String.t()
        }

  @doc "Builds a successful formatter result from captured stdout and stderr."
  @spec new(String.t(), String.t()) :: t()
  def new(content, diagnostics) when is_binary(content) and is_binary(diagnostics) do
    %__MODULE__{content: content, diagnostics: diagnostics}
  end
end
