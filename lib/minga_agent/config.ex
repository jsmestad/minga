defmodule MingaAgent.Config do
  @moduledoc """
  Single source of truth for all agent tunables.

  Reads user-facing settings from `Minga.Config.Options` and defines
  sensible defaults for internal tunables. No other agent module should
  define `@default_*` constants or call `Config.get(:agent_*)` directly.

  Call `resolve/0` once at session or provider init, then thread the
  resulting `%Config{}` through state and function arguments.

  ## Adding a new setting

  1. Add the field to the struct and `@type t`
  2. Add the default value in `defstruct`
  3. If user-configurable, register it in `Minga.Config.Options` and
     read it in `resolve/0`
  4. If internal-only, the struct default is sufficient
  """

  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.Registry, as: HookRegistry

  @unconfigured_model "unknown"

  defstruct [
    # Provider & model
    provider: :auto,
    model: @unconfigured_model,
    models: [],

    # Generation
    max_tokens: 16_384,
    prompt_cache: true,

    # Safety
    max_turns: 100,
    max_retries: 3,
    max_cost: nil,

    # Tool approval and hooks
    tool_approval: :destructive,
    destructive_tools:
      ~w(write_file edit_file multi_edit_file apply_diff delete_file shell git_stage git_commit rename),
    tool_permissions: nil,
    agent_hooks: [],

    # System prompt
    system_prompt: "",
    append_system_prompt: "",

    # API endpoint
    api_base_url: "",
    api_base_url_override: nil,
    api_endpoints: nil,

    # MCP
    mcp_servers: [],

    # Compaction
    compaction_threshold: 0.80,
    compaction_keep_recent: 6,

    # Timeouts
    approval_timeout_ms: 300_000,
    subagent_timeout_ms: 300_000,
    shell_debounce_ms: 200,

    # File mentions
    max_file_size: 256 * 1024,
    max_image_size: 5 * 1024 * 1024,
    max_mention_candidates: 10,

    # Memory
    memory_max_tokens: 4_000,

    # Notifications
    notifications: true,
    notify_on: [:approval, :complete, :error],
    notify_debounce_ms: 5_000,

    # UI
    panel_split: 65,
    diff_size_threshold: 1_048_576,

    # Session
    session_retention_days: 30,
    save_debounce_ms: 500,
    auto_context: true
  ]

  @type t :: %__MODULE__{
          provider: :auto | :native | String.t(),
          model: String.t(),
          models: [String.t()],
          max_tokens: pos_integer(),
          prompt_cache: boolean(),
          max_turns: pos_integer(),
          max_retries: non_neg_integer(),
          max_cost: float() | nil,
          tool_approval: :destructive | :all | :none,
          destructive_tools: [String.t()],
          tool_permissions: map() | nil,
          agent_hooks: [Hook.t()],
          system_prompt: String.t(),
          append_system_prompt: String.t(),
          api_base_url: String.t(),
          api_base_url_override: String.t() | nil,
          api_endpoints: map() | nil,
          mcp_servers: [MingaAgent.MCP.ServerConfig.t() | map()],
          compaction_threshold: float() | nil,
          compaction_keep_recent: pos_integer(),
          approval_timeout_ms: pos_integer(),
          subagent_timeout_ms: pos_integer(),
          shell_debounce_ms: pos_integer(),
          max_file_size: pos_integer(),
          max_image_size: pos_integer(),
          max_mention_candidates: pos_integer(),
          memory_max_tokens: pos_integer(),
          notifications: boolean(),
          notify_on: [atom()],
          notify_debounce_ms: pos_integer(),
          panel_split: pos_integer(),
          diff_size_threshold: pos_integer(),
          session_retention_days: pos_integer(),
          save_debounce_ms: pos_integer(),
          auto_context: boolean()
        }

  @doc """
  Builds a `%Config{}` from `Options` with struct defaults as fallbacks.

  Safe to call before the Options ETS table exists (e.g., in tests or
  standalone usage). When Options is unavailable, all fields use their
  struct defaults.
  """
  @spec resolve() :: t()
  def resolve do
    %__MODULE__{
      provider: get(:agent_provider, :auto),
      model: resolve_model(),
      models: get(:agent_models, []),
      max_tokens: get(:agent_max_tokens, 16_384),
      prompt_cache: get(:agent_prompt_cache, true),
      max_turns: get(:agent_max_turns, 100),
      max_retries: get(:agent_max_retries, 3),
      max_cost: get(:agent_max_cost, nil),
      tool_approval: get(:agent_tool_approval, :destructive),
      destructive_tools:
        get(
          :agent_destructive_tools,
          ~w(write_file edit_file multi_edit_file apply_diff delete_file shell git_stage git_commit rename)
        ),
      tool_permissions: get(:agent_tool_permissions, nil),
      agent_hooks: merged_agent_hooks(get(:agent_hooks, [])),
      system_prompt: get(:agent_system_prompt, ""),
      append_system_prompt: get(:agent_append_system_prompt, ""),
      api_base_url: get(:agent_api_base_url, ""),
      api_base_url_override: non_empty_env("MINGA_API_BASE_URL"),
      api_endpoints: get(:agent_api_endpoints, nil),
      mcp_servers: get(:agent_mcp_servers, []),
      compaction_threshold: get(:agent_compaction_threshold, 0.80),
      compaction_keep_recent: get(:agent_compaction_keep_recent, 6),
      approval_timeout_ms: get(:agent_approval_timeout, 300_000),
      subagent_timeout_ms: get(:agent_subagent_timeout, 300_000),
      max_file_size: get(:agent_mention_max_file_size, 256 * 1024),
      notifications: get(:agent_notifications, true),
      notify_on: get(:agent_notify_on, [:approval, :complete, :error]),
      notify_debounce_ms: get(:agent_notify_debounce, 5_000),
      panel_split: get(:agent_panel_split, 65),
      diff_size_threshold: get(:agent_diff_size_threshold, 1_048_576),
      session_retention_days: get(:agent_session_retention_days, 30),
      auto_context: get(:agent_auto_context, true)
    }
  end

  @doc "Returns the model used for new sessions when the user has not explicitly configured one."
  @spec default_model() :: String.t()
  def default_model, do: resolve_model()

  @doc "Returns the internal sentinel used when no configured provider has an available model."
  @spec unconfigured_model() :: String.t()
  def unconfigured_model, do: @unconfigured_model

  @doc "Returns a config with agent hooks disabled."
  @spec without_hooks(t()) :: t()
  def without_hooks(%__MODULE__{} = config), do: %{config | agent_hooks: []}

  @spec merged_agent_hooks(term()) :: [Hook.t()]
  defp merged_agent_hooks(raw_hooks) do
    raw_hooks
    |> normalize_hooks()
    |> Kernel.++(HookRegistry.all())
    |> Enum.uniq_by(&hook_key/1)
  end

  @spec hook_key(Hook.t()) :: term()
  defp hook_key(hook) do
    {hook.event, hook.type, hook.tool_pattern, hook.command, hook.module, hook.function,
     hook.extension_source, hook.extension_module}
  end

  @doc "Normalizes raw `:agent_hooks` config declarations into hook structs."
  @spec normalize_hooks(term()) :: [Hook.t()]
  def normalize_hooks(nil), do: []

  def normalize_hooks(raw_hooks) when is_list(raw_hooks) do
    raw_hooks
    |> Enum.map(&Hook.normalize/1)
    |> Enum.flat_map(fn
      {:ok, hook} -> [hook]
      {:error, message} -> raise ArgumentError, message
    end)
  end

  def normalize_hooks(_raw_hooks), do: raise(ArgumentError, ":agent_hooks must be a list")

  @doc """
  Returns the configured model, then the first available credential-backed model.

  Safe to call before Config is running (catches exits). If no provider has credentials, returns the internal `"unknown"` sentinel rather than pretending a specific vendor model is ready.
  """
  @spec resolve_model() :: String.t()
  def resolve_model do
    configured_model() || first_available_model() || @unconfigured_model
  end

  @doc "Returns the explicitly configured model, or nil when the user has not chosen one."
  @spec configured_model() :: String.t() | nil
  def configured_model do
    case get(:agent_model, nil) do
      model when is_binary(model) and model != "" -> model
      model when model != nil -> to_string(model)
      _other -> nil
    end
  end

  @doc """
  Returns the configured provider, falling back to `:auto`.

  Safe to call before Config is running (catches exits).
  """
  @spec resolve_provider() :: :auto | :native | String.t()
  def resolve_provider do
    get(:agent_provider, :auto)
  end

  @doc """
  Splits a model spec into `{model, provider}` regardless of whether the user wrote `provider:model` or `model@provider`.

  Returns `{bare_model, nil}` when no provider is encoded in the string.

  ## Examples

      iex> MingaAgent.Config.split_model_spec("anthropic:claude-sonnet-4")
      {"claude-sonnet-4", "anthropic"}

      iex> MingaAgent.Config.split_model_spec("claude-sonnet-4@anthropic")
      {"claude-sonnet-4", "anthropic"}

      iex> MingaAgent.Config.split_model_spec("claude-sonnet-4")
      {"claude-sonnet-4", nil}
  """
  @spec split_model_spec(String.t()) :: {String.t(), String.t() | nil}
  def split_model_spec(model) when is_binary(model) do
    case String.split(model, "@", parts: 2) do
      [name, provider] when name != "" and provider != "" ->
        {name, String.downcase(provider)}

      _ ->
        case String.split(model, ":", parts: 2) do
          [provider, name] when provider != "" and name != "" -> {name, String.downcase(provider)}
          [name] -> {name, nil}
          _ -> {model, nil}
        end
    end
  end

  @doc """
  Strips the provider encoding from a model spec string.

  Returns the bare model name. If there's no provider encoding, returns the string unchanged.
  """
  @spec strip_provider_prefix(String.t()) :: String.t()
  def strip_provider_prefix(model) when is_binary(model) do
    {name, _provider} = split_model_spec(model)
    name
  end

  @doc """
  Extracts the provider prefix from a model spec string.

  Returns the provider name, or `""` if no prefix is present.
  """
  @spec extract_provider_prefix(String.t()) :: String.t()
  def extract_provider_prefix(model) when is_binary(model) do
    case split_model_spec(model) do
      {_name, provider} when is_binary(provider) -> provider
      _ -> ""
    end
  end

  @spec first_available_model() :: String.t() | nil
  defp first_available_model do
    case MingaAgent.ModelCatalog.available_models("") do
      [%{"id" => model} | _rest] when is_binary(model) and model != "" -> model
      _other -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @spec non_empty_env(String.t()) :: String.t() | nil
  defp non_empty_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # Reads a single option from the Options ETS table, falling back to the
  # given default when the table doesn't exist yet (tests, standalone).
  @spec get(atom(), term()) :: term()
  defp get(key, default) do
    Minga.Config.get(key)
  rescue
    ArgumentError -> default
  catch
    :exit, _ -> default
  end
end
