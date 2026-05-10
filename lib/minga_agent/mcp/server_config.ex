defmodule MingaAgent.MCP.ServerConfig do
  @moduledoc """
  Normalized configuration for one session-scoped MCP server.

  User config may use atom or string keys. The normalized struct keeps the
  process launch shape explicit so the native provider and MCP client do not
  pass raw config maps across module boundaries.
  """

  @enforce_keys [:name, :command]
  defstruct [:name, :command, args: [], env: %{}]

  @typedoc "One MCP stdio server declaration."
  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: %{String.t() => String.t()}
        }

  @doc "Normalizes a user config map into a `ServerConfig` struct."
  @spec normalize(map() | t() | nil) :: {:ok, t() | nil} | {:error, String.t()}
  def normalize(nil), do: {:ok, nil}
  def normalize(%__MODULE__{} = config), do: {:ok, config}

  def normalize(config) when is_map(config) do
    with {:ok, name} <- fetch_string(config, :name),
         {:ok, command} <- fetch_string(config, :command),
         {:ok, args} <- fetch_args(config),
         {:ok, env} <- fetch_env(config) do
      {:ok, %__MODULE__{name: name, command: command, args: args, env: env}}
    end
  end

  def normalize(other),
    do: {:error, "MCP server config must be a map or nil, got: #{inspect(other)}"}

  @spec fetch_string(map(), atom()) :: {:ok, String.t()} | {:error, String.t()}
  defp fetch_string(config, key) do
    case fetch(config, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_binary(value) -> {:error, "MCP server #{key} cannot be empty"}
      nil -> {:error, "MCP server #{key} is required"}
      value -> {:error, "MCP server #{key} must be a string, got: #{inspect(value)}"}
    end
  end

  @spec fetch_args(map()) :: {:ok, [String.t()]} | {:error, String.t()}
  defp fetch_args(config) do
    case fetch(config, :args) do
      nil -> {:ok, []}
      args when is_list(args) -> normalize_string_list(args, :args)
      other -> {:error, "MCP server args must be a list of strings, got: #{inspect(other)}"}
    end
  end

  @spec fetch_env(map()) :: {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  defp fetch_env(config) do
    case fetch(config, :env) do
      nil ->
        {:ok, %{}}

      env when is_map(env) ->
        normalize_env(env)

      other ->
        {:error, "MCP server env must be a map of string keys and values, got: #{inspect(other)}"}
    end
  end

  @spec normalize_string_list([term()], atom()) :: {:ok, [String.t()]} | {:error, String.t()}
  defp normalize_string_list(values, key) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, "MCP server #{key} must contain only strings, got: #{inspect(values)}"}
    end
  end

  @spec normalize_env(map()) :: {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  defp normalize_env(env) do
    pairs = Enum.map(env, fn {key, value} -> {to_env_key(key), value} end)

    if Enum.all?(pairs, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      {:ok, Map.new(pairs)}
    else
      {:error, "MCP server env must contain string keys and values, got: #{inspect(env)}"}
    end
  end

  @spec to_env_key(term()) :: term()
  defp to_env_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_env_key(key), do: key

  @spec fetch(map(), atom()) :: term()
  defp fetch(config, key) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end
end
