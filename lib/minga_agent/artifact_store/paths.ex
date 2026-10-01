defmodule MingaAgent.ArtifactStore.Paths do
  @moduledoc "Namespace-confined paths for one random artifact identifier."

  @type t :: %__MODULE__{
          blob_partial: String.t(),
          index_partial: String.t(),
          blob: String.t(),
          index: String.t()
        }

  @enforce_keys [:blob_partial, :index_partial, :blob, :index]
  defstruct @enforce_keys

  @doc "Builds paths from a validated random base64url artifact identifier."
  @spec new(String.t(), String.t()) :: {:ok, t()} | {:error, :invalid_artifact_id}
  def new(directory, id) when is_binary(directory) and is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{32,64}\z/, id) do
      {:ok,
       %__MODULE__{
         blob_partial: Path.join(directory, id <> ".blob.partial"),
         index_partial: Path.join(directory, id <> ".index.partial"),
         blob: Path.join(directory, id <> ".blob"),
         index: Path.join(directory, id <> ".index")
       }}
    else
      {:error, :invalid_artifact_id}
    end
  end

  def new(_directory, _id), do: {:error, :invalid_artifact_id}
end
