defmodule MingaAgent.Session.ProviderLifecycle do
  @moduledoc """
  Owns provider identity, configuration, process attachment, and retry state for one agent session.

  Transitions are pure. `MingaAgent.Session` remains responsible for provider calls, process monitoring, timers, and code lease effects.
  """

  alias Minga.Extension.CodeLease

  @default_base_delay_ms 2_000
  @default_max_delay_ms 30_000
  @default_max_attempts 5
  @default_window_ms 60_000

  @typedoc "Provider restart backoff policy."
  @type restart_policy :: %{
          base_delay_ms: pos_integer(),
          max_attempts: pos_integer(),
          max_delay_ms: pos_integer(),
          window_ms: non_neg_integer()
        }

  @typedoc "Provider retry history retained across process replacements."
  @type retry_state :: %{
          attempts: non_neg_integer(),
          window_started_at_ms: integer() | nil,
          failure_reason: term()
        }

  @typedoc "Retry timer identity installed by the Session process."
  @type retry_timer :: {timer_ref :: reference(), token :: reference()}

  @typedoc "External effect for the Session process to execute after a transition."
  @type effect ::
          {:cancel_timer, reference()}
          | {:release_lease, CodeLease.t()}
          | {:stop_provider, pid()}

  @typedoc "Ordered external effects returned by a pure lifecycle transition."
  @type effects :: [effect()]

  @typedoc "Current provider lifecycle phase with phase-specific state."
  @type phase ::
          {:stopped, CodeLease.t() | nil, retry_state()}
          | {:starting, CodeLease.t() | nil, retry_state()}
          | {:running, pid(), CodeLease.t() | nil, retry_state()}
          | {:retrying, retry_state(), retry_timer() | nil}
          | {:terminal_failure, retry_state()}

  @typedoc "Provider lifecycle state owned by a session."
  @type t :: %__MODULE__{
          module: module(),
          id: String.t(),
          source: Minga.Extension.ContributionCleanup.contribution_source(),
          opts: keyword(),
          model_name: String.t(),
          provider_name: String.t(),
          restart_policy: restart_policy(),
          phase: phase()
        }

  @enforce_keys [
    :module,
    :id,
    :source,
    :opts,
    :model_name,
    :provider_name,
    :restart_policy,
    :phase
  ]
  defstruct [
    :module,
    :id,
    :source,
    :model_name,
    :provider_name,
    :phase,
    opts: [],
    restart_policy: %{}
  ]

  @doc "Builds the initial lifecycle value from resolved provider configuration."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      module: Keyword.fetch!(opts, :module),
      id: Keyword.fetch!(opts, :id),
      source: Keyword.fetch!(opts, :source),
      opts: Keyword.fetch!(opts, :provider_opts),
      model_name: Keyword.fetch!(opts, :model_name),
      provider_name: Keyword.fetch!(opts, :provider_name),
      restart_policy: restart_policy(Keyword.get(opts, :restart, [])),
      phase: {:stopped, Keyword.get(opts, :lease), initial_retry_state()}
    }
  end

  @doc "Returns true in guards when no provider process is attached."
  defguard is_detached(lifecycle)
           when is_struct(lifecycle, __MODULE__) and elem(lifecycle.phase, 0) != :running

  @doc "Returns the active provider process, or nil when no provider is attached."
  @spec pid(t()) :: pid() | nil
  def pid(%__MODULE__{phase: {:running, pid, _lease, _retry}}), do: pid
  def pid(%__MODULE__{}), do: nil

  @doc "Returns the active provider code lease, or nil when no provider is attached."
  @spec lease(t()) :: CodeLease.t() | nil
  def lease(%__MODULE__{phase: {:running, _pid, lease, _retry}}), do: lease
  def lease(%__MODULE__{phase: {:stopped, lease, _retry}}), do: lease
  def lease(%__MODULE__{phase: {:starting, lease, _retry}}), do: lease
  def lease(%__MODULE__{}), do: nil

  @doc "Returns the installed retry timer identity, if a retry is scheduled."
  @spec retry_timer(t()) :: retry_timer() | nil
  def retry_timer(%__MODULE__{phase: {:retrying, _retry, timer}}), do: timer
  def retry_timer(%__MODULE__{}), do: nil

  @doc "Returns the number of retries attempted in the current backoff window."
  @spec retry_attempts(t()) :: non_neg_integer()
  def retry_attempts(%__MODULE__{} = lifecycle), do: retry_state(lifecycle).attempts

  @doc "Returns the start of the current retry window."
  @spec retry_window_started_at_ms(t()) :: integer() | nil
  def retry_window_started_at_ms(%__MODULE__{} = lifecycle),
    do: retry_state(lifecycle).window_started_at_ms

  @doc "Returns the current lifecycle phase name."
  @spec phase(t()) :: :stopped | :starting | :running | :retrying | :terminal_failure
  def phase(%__MODULE__{phase: {phase, _retry}}), do: phase
  def phase(%__MODULE__{phase: {phase, _retry, _timer}}), do: phase
  def phase(%__MODULE__{phase: {phase, _pid, _lease, _retry}}), do: phase

  @doc "Returns the most recent provider failure reason."
  @spec failure_reason(t()) :: term()
  def failure_reason(%__MODULE__{} = lifecycle), do: retry_state(lifecycle).failure_reason

  @doc "Begins provider startup unless a provider is already attached."
  @spec start(t()) :: {:start, t(), effects()} | {:active, t(), effects()}
  def start(%__MODULE__{phase: {:running, _pid, _lease, _retry}} = lifecycle),
    do: {:active, lifecycle, []}

  def start(%__MODULE__{} = lifecycle) do
    next = %{lifecycle | phase: {:starting, lease(lifecycle), retry_state(lifecycle)}}
    {:start, next, cancel_timer_effects(lifecycle)}
  end

  @doc "Installs a source-code lease acquired while provider startup is in progress."
  @spec install_lease(t(), CodeLease.t()) :: {:ok, t()} | {:invalid_phase, t()}
  def install_lease(
        %__MODULE__{phase: {:starting, _lease, retry}} = lifecycle,
        %CodeLease{} = lease
      ) do
    {:ok, %{lifecycle | phase: {:starting, lease, retry}}}
  end

  def install_lease(%__MODULE__{} = lifecycle, %CodeLease{}), do: {:invalid_phase, lifecycle}

  @doc "Attaches a started provider process."
  @spec attach(t(), pid()) :: {t(), effects()}
  def attach(%__MODULE__{} = lifecycle, pid) when is_pid(pid) do
    retry = %{retry_state(lifecycle) | failure_reason: nil}
    next = %{lifecycle | phase: {:running, pid, lease(lifecycle), retry}}
    {next, cancel_timer_effects(lifecycle)}
  end

  @doc "Records provider failure and detaches the failed process and lease."
  @spec failure(t(), term()) :: {t(), effects()}
  def failure(%__MODULE__{} = lifecycle, reason) do
    retry = %{retry_state(lifecycle) | failure_reason: reason}
    next = %{lifecycle | phase: {:stopped, nil, retry}}
    {next, release_lease_effects(lifecycle) ++ cancel_timer_effects(lifecycle)}
  end

  @doc "Calculates the next retry or records terminal retry exhaustion."
  @spec retry(t(), term(), integer()) ::
          {:retry, t(), pos_integer(), effects()} | {:terminal_failure, t(), effects()}
  def retry(%__MODULE__{} = lifecycle, reason, now_ms) when is_integer(now_ms) do
    retry = %{retry_state(lifecycle) | failure_reason: reason}
    {attempts, window_started_at_ms} = next_retry_window(retry, lifecycle.restart_policy, now_ms)
    effects = cancel_timer_effects(lifecycle)

    if attempts > lifecycle.restart_policy.max_attempts do
      {:terminal_failure, %{lifecycle | phase: {:terminal_failure, retry}}, effects}
    else
      next_retry = %{
        retry
        | attempts: attempts,
          window_started_at_ms: window_started_at_ms
      }

      next = %{lifecycle | phase: {:retrying, next_retry, nil}}
      {:retry, next, retry_delay_ms(lifecycle.restart_policy, attempts), effects}
    end
  end

  @doc "Installs the timer identity created by the Session process for a scheduled retry."
  @spec install_retry_timer(t(), reference(), reference()) :: {:ok, t()} | {:invalid_phase, t()}
  def install_retry_timer(
        %__MODULE__{phase: {:retrying, retry, _timer}} = lifecycle,
        timer_ref,
        token
      )
      when is_reference(timer_ref) and is_reference(token) do
    {:ok, %{lifecycle | phase: {:retrying, retry, {timer_ref, token}}}}
  end

  def install_retry_timer(%__MODULE__{} = lifecycle, _timer_ref, _token),
    do: {:invalid_phase, lifecycle}

  @doc "Consumes a matching retry timer token and rejects stale timer messages."
  @spec retry_due(t(), reference()) :: {:start, t()} | {:stale, t()}
  def retry_due(
        %__MODULE__{phase: {:retrying, retry, {_timer_ref, token}}} = lifecycle,
        token
      ) do
    {:start, %{lifecycle | phase: {:starting, nil, retry}}}
  end

  def retry_due(%__MODULE__{} = lifecycle, _token), do: {:stale, lifecycle}

  @doc "Clears retry history for an explicit provider restart."
  @spec reset_retry(t()) :: {t(), effects()}
  def reset_retry(%__MODULE__{phase: {:running, pid, lease, _retry}} = lifecycle) do
    next = %{lifecycle | phase: {:running, pid, lease, initial_retry_state()}}
    {next, cancel_timer_effects(lifecycle)}
  end

  def reset_retry(%__MODULE__{} = lifecycle) do
    next = %{lifecycle | phase: {:stopped, lease(lifecycle), initial_retry_state()}}
    {next, cancel_timer_effects(lifecycle)}
  end

  @doc "Replaces the model configuration while preserving process and retry identity."
  @spec replace(t(), String.t(), String.t(), keyword()) :: t()
  def replace(%__MODULE__{} = lifecycle, model_name, provider_name, provider_opts)
      when is_binary(model_name) and is_binary(provider_name) and is_list(provider_opts) do
    %{
      lifecycle
      | model_name: model_name,
        provider_name: provider_name,
        opts: provider_opts
    }
  end

  @doc "Stops the lifecycle and clears attached process, lease, retry, and failure state."
  @spec stop(t()) :: {t(), effects()}
  def stop(%__MODULE__{} = lifecycle) do
    next = %{lifecycle | phase: {:stopped, nil, initial_retry_state()}}

    effects =
      stop_provider_effects(lifecycle) ++
        release_lease_effects(lifecycle) ++ cancel_timer_effects(lifecycle)

    {next, effects}
  end

  @doc "Returns true when automatic retries are exhausted."
  @spec terminal_failure?(t()) :: boolean()
  def terminal_failure?(%__MODULE__{phase: {:terminal_failure, _retry}}), do: true
  def terminal_failure?(%__MODULE__{}), do: false

  @spec stop_provider_effects(t()) :: effects()
  defp stop_provider_effects(%__MODULE__{} = lifecycle) do
    case pid(lifecycle) do
      pid when is_pid(pid) -> [{:stop_provider, pid}]
      nil -> []
    end
  end

  @spec cancel_timer_effects(t()) :: effects()
  defp cancel_timer_effects(%__MODULE__{} = lifecycle) do
    case retry_timer(lifecycle) do
      {timer_ref, _token} -> [{:cancel_timer, timer_ref}]
      nil -> []
    end
  end

  @spec release_lease_effects(t()) :: effects()
  defp release_lease_effects(%__MODULE__{} = lifecycle) do
    case lease(lifecycle) do
      %CodeLease{} = lease -> [{:release_lease, lease}]
      nil -> []
    end
  end

  @spec initial_retry_state() :: retry_state()
  defp initial_retry_state do
    %{attempts: 0, window_started_at_ms: nil, failure_reason: nil}
  end

  @spec retry_state(t()) :: retry_state()
  defp retry_state(%__MODULE__{phase: {:stopped, _lease, retry}}), do: retry
  defp retry_state(%__MODULE__{phase: {:starting, _lease, retry}}), do: retry
  defp retry_state(%__MODULE__{phase: {:running, _pid, _lease, retry}}), do: retry
  defp retry_state(%__MODULE__{phase: {:retrying, retry, _timer}}), do: retry
  defp retry_state(%__MODULE__{phase: {:terminal_failure, retry}}), do: retry

  @spec restart_policy(keyword()) :: restart_policy()
  defp restart_policy(opts) do
    %{
      base_delay_ms: Keyword.get(opts, :base_delay_ms, @default_base_delay_ms),
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      max_delay_ms: Keyword.get(opts, :max_delay_ms, @default_max_delay_ms),
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms)
    }
  end

  @spec next_retry_window(retry_state(), restart_policy(), integer()) ::
          {pos_integer(), integer()}
  defp next_retry_window(
         %{window_started_at_ms: window_started_at_ms, attempts: attempts},
         %{window_ms: window_ms},
         now_ms
       )
       when is_integer(window_started_at_ms) and now_ms - window_started_at_ms <= window_ms do
    {attempts + 1, window_started_at_ms}
  end

  defp next_retry_window(_retry, _policy, now_ms), do: {1, now_ms}

  @spec retry_delay_ms(restart_policy(), pos_integer()) :: pos_integer()
  defp retry_delay_ms(%{base_delay_ms: base_delay_ms, max_delay_ms: max_delay_ms}, attempts) do
    exponential = base_delay_ms * round(:math.pow(2, attempts - 1))
    min(exponential, max_delay_ms)
  end
end
