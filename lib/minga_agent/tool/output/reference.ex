defmodule MingaAgent.Tool.Output.Reference do
  @moduledoc "An address for immutable captured bytes, with no filesystem path or source replay instruction."

  @type t :: %__MODULE__{
          token: String.t(),
          media_type: String.t(),
          bytes: non_neg_integer(),
          items: non_neg_integer() | nil,
          sha256: String.t()
        }

  @enforce_keys [:token, :media_type, :bytes, :sha256]
  defstruct [:token, :media_type, :bytes, :sha256, :items]

  @doc "Builds a reference from validated persisted facts."
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_reference}
  def new(attrs) when is_list(attrs) do
    build(
      Keyword.get(attrs, :token),
      Keyword.get(attrs, :media_type),
      Keyword.get(attrs, :bytes),
      Keyword.get(attrs, :items),
      Keyword.get(attrs, :sha256)
    )
  end

  @doc "Computes the namespace identity without exposing the durable session ID."
  @spec namespace(String.t()) :: String.t()
  def namespace(session_id) when is_binary(session_id), do: digest(session_id)

  @doc "Builds a token from a durable namespace and a random artifact ID."
  @spec token(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_reference}
  def token(session_id, artifact_id) when is_binary(session_id) and is_binary(artifact_id) do
    value = "artifact:1:#{namespace(session_id)}:#{artifact_id}"

    case parse(value) do
      {:ok, _, _} -> {:ok, value}
      {:error, _} = error -> error
    end
  end

  @doc "Decodes a token without granting authorization to its namespace."
  @spec parse(String.t()) :: {:ok, String.t(), String.t()} | {:error, :invalid_reference}
  def parse(token) when is_binary(token) do
    case Regex.run(~r/\Aartifact:1:([0-9a-f]{64}):([A-Za-z0-9_-]{32,64})\z/, token) do
      [_, namespace, id] -> {:ok, namespace, id}
      _ -> {:error, :invalid_reference}
    end
  end

  def parse(_), do: {:error, :invalid_reference}

  @doc "Hashes the exact captured bytes."
  @spec digest(binary()) :: String.t()
  def digest(bytes) when is_binary(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @spec build(term(), term(), term(), term(), term()) :: {:ok, t()} | {:error, :invalid_reference}
  defp build(token, media_type, bytes, items, sha256)
       when is_binary(token) and is_binary(media_type) and byte_size(media_type) > 0 and
              is_integer(bytes) and bytes >= 0 and
              (is_nil(items) or (is_integer(items) and items >= 0)) and is_binary(sha256) do
    with {:ok, _, _} <- parse(token), true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256) do
      {:ok,
       %__MODULE__{
         token: token,
         media_type: media_type,
         bytes: bytes,
         items: items,
         sha256: sha256
       }}
    else
      _ -> {:error, :invalid_reference}
    end
  end

  defp build(_, _, _, _, _), do: {:error, :invalid_reference}
end
