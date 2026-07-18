defmodule MingaAgent.EventLog.Payload do
  @moduledoc """
  Normalizes event payloads and enforces their serialized size boundary.

  External-term sizing protects admission before a payload enters the EventLog mailbox. Preparation sanitizes the payload and measures the JSON bytes charged to bounded outstanding work.
  """

  @max_event_bytes 256 * 1024
  @max_depth 64
  @secret_keys MapSet.new(
                 ~w(api_key apikey token access_token refresh_token secret password credential credentials authorization remote_token)
               )

  @type error :: :payload_too_large | :invalid_payload

  @doc "Returns the bounded external-term size used for pre-mailbox admission."
  @spec external_size(map()) :: {:ok, non_neg_integer()} | {:error, error()}
  def external_size(payload) when is_map(payload) do
    with {:ok, bytes} <- measure_external(payload),
         :ok <- enforce_size(bytes) do
      {:ok, bytes}
    else
      {:error, :payload_too_large} = error -> error
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  @doc "Sanitizes a payload and returns the exact JSON byte size charged to admission."
  @spec prepare(map()) :: {:ok, map(), non_neg_integer()} | {:error, error()}
  def prepare(payload) when is_map(payload) do
    with {:ok, sanitized} <- sanitize(payload, 0),
         {:ok, bytes} <- measure_encoded(sanitized),
         :ok <- enforce_size(bytes) do
      {:ok, sanitized, bytes}
    else
      {:error, :payload_too_large} = error -> error
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  @spec measure_external(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp measure_external(payload) do
    {:ok, :erlang.external_size(payload)}
  rescue
    _exception -> {:error, :invalid_external_term}
  end

  @spec measure_encoded(map()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp measure_encoded(payload) do
    {:ok, payload |> JSON.encode!() |> byte_size()}
  rescue
    _exception -> {:error, :not_json_encodable}
  end

  @spec enforce_size(non_neg_integer()) :: :ok | {:error, :payload_too_large}
  defp enforce_size(bytes) when bytes <= @max_event_bytes, do: :ok
  defp enforce_size(_bytes), do: {:error, :payload_too_large}

  @spec sanitize(term(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  defp sanitize(_payload, depth) when depth > @max_depth, do: {:error, :payload_too_deep}
  defp sanitize(%_{} = struct, depth), do: sanitize(Map.from_struct(struct), depth + 1)

  defp sanitize(map, depth) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, sanitized_map} ->
      with {:ok, string_key} <- sanitize_key(key),
           {:ok, sanitized} <- sanitize_value(string_key, value, depth) do
        {:cont, {:ok, Map.put(sanitized_map, string_key, sanitized)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp sanitize(list, depth) when is_list(list), do: sanitize_list(list, depth, [])
  defp sanitize(pid, _depth) when is_pid(pid), do: {:ok, "[PID]"}
  defp sanitize(ref, _depth) when is_reference(ref), do: {:ok, "[REFERENCE]"}
  defp sanitize(boolean, _depth) when is_boolean(boolean), do: {:ok, boolean}
  defp sanitize(nil, _depth), do: {:ok, nil}
  defp sanitize(atom, _depth) when is_atom(atom), do: {:ok, Atom.to_string(atom)}

  defp sanitize(binary, _depth) when is_binary(binary) do
    if String.valid?(binary), do: {:ok, binary}, else: {:error, :invalid_utf8}
  end

  defp sanitize(number, _depth) when is_number(number), do: {:ok, number}
  defp sanitize(_other, _depth), do: {:error, :unsupported_payload_type}

  @spec sanitize_list(term(), non_neg_integer(), [term()]) ::
          {:ok, [term()]} | {:error, term()}
  defp sanitize_list([], _depth, acc), do: {:ok, Enum.reverse(acc)}

  defp sanitize_list([value | rest], depth, acc) do
    case sanitize(value, depth + 1) do
      {:ok, sanitized} -> sanitize_list(rest, depth, [sanitized | acc])
      {:error, _reason} = error -> error
    end
  end

  defp sanitize_list(_improper_tail, _depth, _acc), do: {:error, :improper_list}

  @spec sanitize_key(term()) :: {:ok, String.t()} | {:error, term()}
  defp sanitize_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: {:error, :invalid_utf8_key}
  end

  defp sanitize_key(key) when is_atom(key) or is_number(key), do: {:ok, to_string(key)}
  defp sanitize_key(_key), do: {:error, :unsupported_map_key}

  @spec sanitize_value(String.t(), term(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  defp sanitize_value(key, value, depth) do
    if secret_key?(key), do: {:ok, "[REDACTED]"}, else: sanitize(value, depth + 1)
  end

  @spec secret_key?(String.t()) :: boolean()
  defp secret_key?(key) do
    normalized = normalize_secret_key(key)

    MapSet.member?(@secret_keys, normalized) or
      String.ends_with?(normalized, "_token") or
      String.ends_with?(normalized, "_secret") or
      String.contains?(normalized, "api_key") or
      String.contains?(normalized, "password") or
      String.contains?(normalized, "credential") or
      String.contains?(normalized, "authorization")
  end

  @spec normalize_secret_key(String.t()) :: String.t()
  defp normalize_secret_key(key) do
    key
    |> Macro.underscore()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
