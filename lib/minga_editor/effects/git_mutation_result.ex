defmodule MingaEditor.Effects.GitMutationResult do
  @moduledoc "Typed result of a repository mutation worker."

  @enforce_keys [:git_root, :message]
  defstruct [:git_root, :message, :detail]

  @type t :: %__MODULE__{
          git_root: String.t(),
          message: String.t(),
          detail: term() | nil
        }

  @doc "Builds a successful or failed mutation result for domain application."
  @spec new(String.t(), String.t(), term() | nil) :: t()
  def new(git_root, message, detail \\ nil) when is_binary(git_root) and is_binary(message) do
    %__MODULE__{git_root: git_root, message: message, detail: detail}
  end
end
