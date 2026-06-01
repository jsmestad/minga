defmodule MingaAgent.MCP.ServerConfig do
  @moduledoc """
  Normalized configuration for one session-scoped MCP server.

  User config may use atom or string keys. The normalized struct keeps the
  process launch shape explicit so the native provider and MCP client do not
  pass raw config maps across module boundaries.
  """

  @enforce_keys [:name, :command]
  defstruct [:name, :command, args: [], env: %{}, enabled: true, source: :config]

  @typedoc "One MCP stdio server declaration."
  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: %{String.t() => String.t()},
          enabled: boolean(),
          source: Minga.Extension.ContributionCleanup.contribution_source()
        }

  @doc "Normalizes a user config map into a `ServerConfig` struct."
  @spec normalize(map() | t() | nil) :: {:ok, t() | nil} | {:error, String.t()}
  def normalize(nil), do: {:ok, nil}

  def normalize(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> normalize()
  end

  def normalize(config) when is_map(config) do
    with {:ok, name} <- fetch_string(config, :name),
         {:ok, command} <- fetch_string(config, :command),
         {:ok, args} <- fetch_args(config),
         {:ok, env} <- fetch_env(config),
         {:ok, enabled} <- fetch_enabled(config),
         {:ok, source} <- fetch_source(config) do
      {:ok,
       %__MODULE__{
         name: name,
         command: command,
         args: args,
         env: env,
         enabled: enabled,
         source: source
       }}
    end
  end

  def normalize(other),
    do: {:error, "MCP server config must be a map or nil, got: #{inspect(other)}"}

  @doc "Normalizes one or more MCP server configs, filters disabled entries, and rejects duplicate enabled server names."
  @spec normalize_list(nil | map() | t() | [map() | t()]) :: {:ok, [t()]} | {:error, String.t()}
  def normalize_list(nil), do: {:ok, []}
  def normalize_list(%__MODULE__{} = config), do: normalize_list([config])
  def normalize_list(config) when is_map(config), do: normalize_list([config])

  def normalize_list(configs) when is_list(configs) do
    configs
    |> Enum.reduce_while({:ok, []}, &normalize_list_entry/2)
    |> case do
      {:ok, normalized} -> reject_duplicate_names(Enum.reverse(normalized))
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_list(other),
    do:
      {:error, "MCP servers config must be a list of maps, a map, or nil, got: #{inspect(other)}"}

  @spec normalize_list_entry(term(), {:ok, [t()]}) ::
          {:cont, {:ok, [t()]}} | {:halt, {:error, String.t()}}
  defp normalize_list_entry(nil, {:ok, _acc}) do
    {:halt, {:error, "MCP servers config list cannot contain nil entries"}}
  end

  defp normalize_list_entry(config, {:ok, acc}) do
    if disabled?(config) do
      {:cont, {:ok, acc}}
    else
      case normalize(config) do
        {:ok, %__MODULE__{} = normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end
  end

  @spec disabled?(term()) :: boolean()
  defp disabled?(config) when is_map(config), do: fetch(config, :enabled) == false
  defp disabled?(_config), do: false

  @spec reject_duplicate_names([t()]) :: {:ok, [t()]} | {:error, String.t()}
  defp reject_duplicate_names(configs) do
    duplicate_names =
      configs
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    case duplicate_names do
      [] -> {:ok, configs}
      names -> {:error, "MCP server names must be unique, duplicates: #{Enum.join(names, ", ")}"}
    end
  end

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
        {:error,
         "MCP server env must be a map of string or atom keys and string values, got: #{inspect(other)}"}
    end
  end

  @spec fetch_enabled(map()) :: {:ok, boolean()} | {:error, String.t()}
  defp fetch_enabled(config) do
    case fetch(config, :enabled) do
      nil -> {:ok, true}
      enabled when is_boolean(enabled) -> {:ok, enabled}
      other -> {:error, "MCP server enabled must be a boolean, got: #{inspect(other)}"}
    end
  end

  @spec fetch_source(map()) ::
          {:ok, Minga.Extension.ContributionCleanup.contribution_source()} | {:error, String.t()}
  defp fetch_source(config) do
    case fetch(config, :source) do
      nil -> {:ok, :config}
      :builtin -> {:ok, :builtin}
      :config -> {:ok, :config}
      {:extension, name} when is_atom(name) -> {:ok, {:extension, name}}
      other -> {:error, "MCP server source is invalid: #{inspect(other)}"}
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
      {:error,
       "MCP server env must contain string or atom keys and string values, got: #{inspect(env)}"}
    end
  end

  @spec to_env_key(term()) :: term()
  defp to_env_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_env_key(key), do: key

  @spec fetch(map(), atom()) :: term()
  defp fetch(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> Map.get(config, Atom.to_string(key))
    end
  end
end
