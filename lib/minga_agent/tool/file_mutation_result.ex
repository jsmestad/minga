defmodule MingaAgent.Tool.FileMutationResult do
  @moduledoc "A committed file mutation and its separate, model-visible success text."

  alias Minga.Buffer.FileMutation.Receipt

  @enforce_keys [:path, :receipt, :text]
  defstruct @enforce_keys

  @type t :: %__MODULE__{path: String.t(), receipt: Receipt.t(), text: String.t()}

  @doc "Pairs the exact mutation receipt with the resolved tool target and response."
  @spec new(String.t(), Receipt.t(), String.t()) :: t()
  def new(path, %Receipt{} = receipt, text) do
    %__MODULE__{path: path, receipt: receipt, text: text}
  end
end
