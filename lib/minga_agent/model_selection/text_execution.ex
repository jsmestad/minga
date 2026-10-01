defmodule MingaAgent.ModelSelection.TextExecution do
  @moduledoc "Exact text execution contract carried by a model route."

  @enforce_keys [
    :supported,
    :family,
    :wire_protocol,
    :transport,
    :provider_model_id,
    :base_url,
    :path
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          supported: true,
          family: String.t(),
          wire_protocol: String.t(),
          transport: String.t(),
          provider_model_id: String.t(),
          base_url: String.t(),
          path: String.t()
        }

  @doc "Builds and validates a complete text execution contract."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_text_execution | :invalid_base_url}
  def new(attrs) when is_map(attrs) do
    with true <- field(attrs, :supported) == true,
         family when is_binary(family) and family != "" <- field(attrs, :family),
         protocol when is_binary(protocol) and protocol != "" <- field(attrs, :wire_protocol),
         "http" = transport <- field(attrs, :transport),
         model_id when is_binary(model_id) and model_id != "" <- field(attrs, :provider_model_id),
         base_url when is_binary(base_url) and base_url != "" <- field(attrs, :base_url),
         {:ok, normalized_url} <- normalize_base_url(base_url),
         path when is_binary(path) and path != "" <- field(attrs, :path),
         true <- String.starts_with?(path, "/") do
      {:ok,
       %__MODULE__{
         supported: true,
         family: family,
         wire_protocol: protocol,
         transport: transport,
         provider_model_id: model_id,
         base_url: normalized_url,
         path: path
       }}
    else
      {:error, :invalid_base_url} -> {:error, :invalid_base_url}
      _invalid -> {:error, :invalid_text_execution}
    end
  end

  def new(_attrs), do: {:error, :invalid_text_execution}

  @doc "Encodes the execution contract for secret-free persistence."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = execution) do
    %{
      "supported" => true,
      "family" => execution.family,
      "wire_protocol" => execution.wire_protocol,
      "transport" => execution.transport,
      "provider_model_id" => execution.provider_model_id,
      "base_url" => execution.base_url,
      "path" => execution.path
    }
  end

  @doc "Normalizes an HTTP(S) base URL and rejects credential-bearing forms."
  @spec normalize_base_url(String.t()) :: {:ok, String.t()} | {:error, :invalid_base_url}
  def normalize_base_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        path = normalize_path(uri.path)

        normalized = %{
          uri
          | scheme: String.downcase(scheme),
            host: String.downcase(host),
            path: path
        }

        {:ok, URI.to_string(normalized)}

      _invalid ->
        {:error, :invalid_base_url}
    end
  end

  def normalize_base_url(_url), do: {:error, :invalid_base_url}

  @spec normalize_path(String.t() | nil) :: String.t() | nil
  defp normalize_path(nil), do: nil
  defp normalize_path("/"), do: nil
  defp normalize_path(path), do: String.trim_trailing(path, "/")

  @spec field(map(), atom()) :: term()
  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
