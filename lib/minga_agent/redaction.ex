defmodule MingaAgent.Redaction do
  @moduledoc """
  Redacts secrets before values cross logs, UI, telemetry, status, or model-visible tool results.

  Redaction is intentionally conservative. Secret-bearing map keys never expose values, and common token-shaped substrings are replaced even when they appear inside a free-form error string from an external process.
  """

  @redacted "[REDACTED]"

  @secret_key_fragments [
    "api_key",
    "apikey",
    "auth",
    "bearer",
    "client_secret",
    "credential",
    "github_token",
    "jwt",
    "oauth",
    "password",
    "private_key",
    "refresh_token",
    "secret",
    "session",
    "token"
  ]

  @token_patterns [
    {~r/gh[pousr]_[A-Za-z0-9_]{8,}/, @redacted},
    {~r/sk-[A-Za-z0-9_-]{8,}/, @redacted},
    {~r/xox[baprs]-[A-Za-z0-9-]{8,}/, @redacted},
    {~r/(Bearer\s+)[A-Za-z0-9._~+\/-]+=*/i, "\\1#{@redacted}"},
    {~r/([?&](?:access_token|api_key|apikey|auth|code|password|refresh_token|secret|token)=)[^\s&#]+/i,
     "\\1#{@redacted}"},
    {~r/\b([A-Z0-9_]*(?:API[_-]?KEY|AUTH|CREDENTIAL|PASSWORD|SECRET|TOKEN)[A-Z0-9_]*\s*=\s*)[^\s,;]+/i,
     "\\1#{@redacted}"},
    {~r/((?:"|')?[A-Za-z0-9_-]*(?:api[_-]?key|auth|credential|password|secret|token)[A-Za-z0-9_-]*(?:"|')?\s*(?::|=>)\s*)(?!Bearer\s)((?:"|')?)[^"'\s,;}\]]+((?:"|')?)/i,
     "\\1\\2#{@redacted}\\3"},
    {~r/\b((?:api[_-]?key|auth|credential|password|secret|token)\s*:\s*)(?!Bearer\s)[^\s,;]+/i,
     "\\1#{@redacted}"},
    {~r/(--?[A-Za-z0-9_-]*(?:api[-_]?key|auth|credential|password|private[-_]?key|secret|token)[A-Za-z0-9_-]*=)[^\s,;]+/i,
     "\\1#{@redacted}"},
    {~r/(--?(?:api[-_]?key|auth|credential|password|private[-_]?key|secret|token)(?:=|\s+))[^\s,;]+/i,
     "\\1#{@redacted}"}
  ]

  @type redacted :: String.t()

  @doc "Formats and redacts an arbitrary error term."
  @spec format_error(term()) :: redacted()
  def format_error(reason) when is_binary(reason), do: redact_string(reason)
  def format_error(reason), do: reason |> redact_term() |> inspect()

  @doc "Redacts an arbitrary term while preserving safe shape for diagnostics."
  @spec redact_term(term()) :: term()
  def redact_term(%{__struct__: MingaAgent.MCP.ServerConfig} = config) do
    config
    |> Map.from_struct()
    |> Map.update(:args, [], &redact_args/1)
    |> Map.update(:env, %{}, &redact_server_config_env/1)
    |> redact_map()
  end

  def redact_term(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> redact_map()
  end

  def redact_term(map) when is_map(map), do: redact_map(map)

  def redact_term(list) when is_list(list) do
    if List.ascii_printable?(list) do
      list |> to_string() |> redact_string()
    else
      Enum.map(list, &redact_term/1)
    end
  end

  def redact_term(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> redact_tuple_elements()
    |> List.to_tuple()
  end

  def redact_term(value) when is_binary(value), do: redact_string(value)
  def redact_term(value), do: value

  @doc "Redacts an error string or command output string."
  @spec redact_string(String.t()) :: redacted()
  def redact_string(value) when is_binary(value) do
    Enum.reduce(@token_patterns, value, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  @doc "Redacts argv-style secret values while preserving non-secret arguments."
  @spec redact_args(term()) :: term()
  def redact_args(args) when is_list(args) do
    args
    |> redact_args([], false)
    |> Enum.reverse()
  end

  def redact_args(value), do: redact_term(value)

  @doc "Returns true when a key name conventionally carries a secret."
  @spec secret_key?(term()) :: boolean()
  def secret_key?(key) when is_atom(key), do: key |> Atom.to_string() |> secret_key?()

  def secret_key?(key) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    Enum.any?(@secret_key_fragments, &String.contains?(normalized, &1))
  end

  def secret_key?(_key), do: false

  @doc "Redacts environment values while keeping keys visible."
  @spec redact_env(map()) :: %{String.t() => redacted()}
  def redact_env(env) when is_map(env) do
    Map.new(env, fn {key, _value} -> {env_key(key), @redacted} end)
  end

  @spec redact_args([term()], [term()], boolean()) :: [term()]
  defp redact_args([], acc, _redact_next?), do: acc

  defp redact_args([arg | rest], acc, true) when is_binary(arg) do
    redact_args(rest, [@redacted | acc], false)
  end

  defp redact_args([arg | rest], acc, false) when is_binary(arg) do
    redact_args(rest, [redact_string(arg) | acc], secret_flag_without_value?(arg))
  end

  defp redact_args([arg | rest], acc, _redact_next?) do
    redact_args(rest, [redact_term(arg) | acc], false)
  end

  @spec secret_flag_without_value?(String.t()) :: boolean()
  defp secret_flag_without_value?(arg) do
    arg
    |> String.trim_leading("-")
    |> String.split("=", parts: 2)
    |> split_flag_without_value?()
  end

  @spec split_flag_without_value?([String.t()]) :: boolean()
  defp split_flag_without_value?([flag]), do: secret_key?(flag)
  defp split_flag_without_value?([_flag, _value]), do: false
  defp split_flag_without_value?(_parts), do: false

  @spec redact_server_config_env(term()) :: term()
  defp redact_server_config_env(env) when is_map(env), do: redact_env(env)
  defp redact_server_config_env(env), do: redact_term(env)

  @spec redact_tuple_elements([term()]) :: [term()]
  defp redact_tuple_elements([key | values]) when is_atom(key) or is_binary(key) do
    if secret_key?(key) do
      [key | Enum.map(values, fn _value -> @redacted end)]
    else
      [key | Enum.map(values, &redact_term/1)]
    end
  end

  defp redact_tuple_elements(values), do: Enum.map(values, &redact_term/1)

  @spec env_key(term()) :: String.t()
  defp env_key(key) when is_atom(key), do: Atom.to_string(key)
  defp env_key(key) when is_binary(key), do: key
  defp env_key(key), do: key |> redact_term() |> inspect()

  @spec redact_map(map()) :: map()
  defp redact_map(map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key) do
        {key, @redacted}
      else
        {key, redact_term(value)}
      end
    end)
  end
end
