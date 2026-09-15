defmodule Minga.Config.Advice do
  @moduledoc """
  Before/after/around/override advice for editor commands.

  Advice functions wrap existing command execution, similar to Emacs's
  `advice-add` system. Four phases are supported:

  | Phase | Signature | Behavior |
  |-------|-----------|----------|
  | `:before` | `(state -> state)` | Transforms state before the command runs |
  | `:after` | `(state -> state)` | Transforms state after the command runs |
  | `:around` | `((state -> state), state -> state)` | Receives the original execute function; full control over whether/how it runs |
  | `:override` | `(state -> state)` | Completely replaces the command; original never runs |

  Uses ETS with `read_concurrency: true` for zero-contention reads in the
  hot `dispatch_command` path. Writes only happen at config load/reload.

  ## Composition

  Multiple advice functions for the same phase and command run in
  registration order. For `:around`, they nest: the outermost advice
  wraps the next one, which wraps the next, with the original command
  at the center.

  If an `:override` is registered, it replaces the command entirely.
  Multiple overrides chain (last registered wins as the innermost).
  `:before` and `:after` still run around an overridden command.

  Result-returning tool execution uses `invoke/3`. Its around and override
  callbacks return `{:returned, state, result}` or `{:skipped, state}` instead
  of treating an ordinary state map as a result. `wrap/2` retains the existing
  state-to-state editor command contract.

  ## Examples

      # Transform state before save
      Minga.Config.Advice.register(:before, :save, fn state ->
        state
      end)

      # Full control: conditionally skip formatting
      Minga.Config.Advice.register(:around, :format_buffer, fn execute, state ->
        if some_condition?(state) do
          execute.(state)
        else
          # Return state unchanged to skip the command
          state
        end
      end)

      # Completely replace a command
      Minga.Config.Advice.register(:override, :save, fn state ->
        my_custom_save(state)
      end)
  """

  @valid_phases [:before, :after, :around, :override]

  @table __MODULE__

  @circuit_breaker_threshold 5

  @typedoc "Advice phase."
  @type phase :: :before | :after | :around | :override

  @typedoc "Before/after/override advice: transforms editor state."
  @type state_fun :: (map() -> map())

  @typedoc "Around advice: receives the execute function and state."
  @type around_fun :: ((map() -> map()), map() -> map())

  @typedoc "Explicit result of a result-returning advised invocation."
  @type invocation_outcome :: {:returned, map(), term()} | {:skipped, map()}

  # ── Lifecycle ───────────────────────────────────────────────────────────────

  @doc "Starts the process that owns the ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__.Server, opts, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Registers an advice function for a command.

  For `:before`, `:after`, and `:override`, the function has arity 1
  (receives state, returns state). For `:around`, the function has
  arity 2 (receives the execute function and state, returns state).

  Returns `:ok` or `{:error, reason}` if the phase is invalid.
  """
  @spec register(phase(), atom(), function()) :: :ok | {:error, String.t()}
  def register(phase, command, fun) when is_atom(phase) and is_atom(command),
    do: register(@table, phase, command, fun)

  @spec register(atom(), phase(), atom(), function()) :: :ok | {:error, String.t()}
  def register(table, phase, command, fun)
      when is_atom(table) and is_atom(phase) and is_atom(command) do
    cond do
      phase not in @valid_phases ->
        {:error,
         "invalid advice phase: #{inspect(phase)}. Valid phases: #{inspect(@valid_phases)}"}

      phase == :around and not is_function(fun, 2) ->
        {:error, ":around advice must be a 2-arity function (fn execute, state -> state end)"}

      phase != :around and not is_function(fun, 1) ->
        {:error, ":#{phase} advice must be a 1-arity function (fn state -> state end)"}

      true ->
        key = {phase, command}

        existing =
          case :ets.lookup(table, key) do
            [{^key, funs}] -> funs
            [] -> []
          end

        :ets.insert(table, {key, [fun | existing]})
        :ok
    end
  end

  @doc """
  Wraps a command's execute function with all registered advice.

  Returns a function `(state -> state)` that applies before advice,
  then the (possibly around-wrapped or overridden) command, then
  after advice.

  This is the main integration point called by `dispatch_command`.
  """
  @spec wrap(atom(), (map() -> map())) :: (map() -> map())
  def wrap(command, execute) when is_atom(command) and is_function(execute, 1),
    do: wrap(@table, command, execute)

  @spec wrap(atom(), atom(), (map() -> map())) :: (map() -> map())
  def wrap(table, command, execute)
      when is_atom(table) and is_atom(command) and is_function(execute, 1) do
    befores = lookup_funs(table, :before, command)
    afters = lookup_funs(table, :after, command)
    arounds = lookup_funs(table, :around, command)
    overrides = lookup_funs(table, :override, command)

    # If no advice at all, return the original function unchanged
    if befores == [] and afters == [] and arounds == [] and overrides == [] do
      execute
    else
      core = build_core(execute, overrides, arounds)

      fn state ->
        state
        |> run_chain(table, befores, :before, command)
        |> run_core(core, command)
        |> run_chain(table, afters, :after, command)
      end
    end
  end

  @doc """
  Invokes a zero-arity core through the advice registered for `command`.

  Unlike `wrap/2`, this function keeps advice state separate from the core result.
  Around and override advice must return an explicit `t:invocation_outcome/0` to
  return a result. Returning a bare state map explicitly skips the core.
  """
  @spec invoke(atom(), map(), (-> term())) :: invocation_outcome()
  def invoke(command, advice_state, core)
      when is_atom(command) and is_map(advice_state) and is_function(core, 0) do
    invoke(@table, command, advice_state, core)
  end

  @doc false
  @spec invoke(atom(), atom(), map(), (-> term())) :: invocation_outcome()
  def invoke(table, command, advice_state, core)
      when is_atom(table) and is_atom(command) and is_map(advice_state) and
             is_function(core, 0) do
    befores = lookup_funs(table, :before, command)
    afters = lookup_funs(table, :after, command)
    arounds = lookup_funs(table, :around, command)
    overrides = lookup_funs(table, :override, command)

    advice_state
    |> run_invocation_state_chain(table, befores, :before, command)
    |> run_invocation_core(build_invocation_core(table, command, core, overrides, arounds))
    |> run_invocation_after_chain(table, afters, command)
  end

  @doc """
  Returns true if any advice is registered for the given phase and command.
  """
  @spec has_advice?(phase(), atom()) :: boolean()
  def has_advice?(phase, command), do: has_advice?(@table, phase, command)

  @spec has_advice?(atom(), phase(), atom()) :: boolean()
  def has_advice?(table, phase, command) do
    case :ets.lookup(table, {phase, command}) do
      [{_, [_ | _]}] -> true
      _ -> false
    end
  end

  @doc "Returns true if any advice of any phase is registered for the command."
  @spec advised?(atom()) :: boolean()
  def advised?(command), do: advised?(@table, command)

  @spec advised?(atom(), atom()) :: boolean()
  def advised?(table, command) do
    Enum.any?(@valid_phases, &has_advice?(table, &1, command))
  end

  @doc "Returns true if a specific advice function has been disabled by the circuit breaker."
  @spec disabled?(atom(), phase(), atom(), function()) :: boolean()
  def disabled?(table, phase, command, fun) do
    cb_disabled?(table, {:cb_disabled, phase, command, fun})
  end

  @doc "Removes all registered advice and resets circuit breaker state."
  @spec reset() :: :ok
  def reset, do: reset(@table)

  @spec reset(atom()) :: :ok
  def reset(table) do
    :ets.delete_all_objects(table)
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec lookup_funs(atom(), phase(), atom()) :: [function()]
  defp lookup_funs(table, phase, command) do
    case :ets.lookup(table, {phase, command}) do
      [{_, funs}] -> Enum.reverse(funs)
      [] -> []
    end
  end

  @spec build_invocation_core(atom(), atom(), (-> term()), [state_fun()], [around_fun()]) ::
          (map() -> invocation_outcome())
  defp build_invocation_core(table, command, core, overrides, arounds) do
    base = build_invocation_base(table, command, core, overrides)

    arounds
    |> Enum.reject(&cb_disabled?(table, {:cb_disabled, :around, command, &1}))
    |> Enum.reverse()
    |> Enum.reduce(base, &wrap_invocation_around(&1, &2, table, command))
  end

  @spec wrap_invocation_around(function(), (map() -> invocation_outcome()), atom(), atom()) ::
          (map() -> invocation_outcome())
  defp wrap_invocation_around(around_fun, inner, table, command) do
    fn state -> invoke_around_callback(table, command, around_fun, inner, state) end
  end

  @spec invoke_around_callback(atom(), atom(), function(), function(), map()) ::
          invocation_outcome()
  defp invoke_around_callback(table, command, around_fun, inner, state) do
    run_invocation_callback(table, :around, command, around_fun, state, fn ->
      around_fun.(inner, state)
    end)
  end

  @spec build_invocation_base(atom(), atom(), (-> term()), [state_fun()]) ::
          (map() -> invocation_outcome())
  defp build_invocation_base(table, command, core, overrides) do
    case last_enabled_override(table, command, overrides) do
      nil ->
        fn state -> return_invocation_core(core, state) end

      override_fun ->
        fn state -> invoke_override_callback(table, command, override_fun, state) end
    end
  end

  @spec last_enabled_override(atom(), atom(), [state_fun()]) :: state_fun() | nil
  defp last_enabled_override(table, command, overrides) do
    overrides
    |> Enum.reverse()
    |> Enum.find(&(not cb_disabled?(table, {:cb_disabled, :override, command, &1})))
  end

  @spec return_invocation_core((-> term()), map()) :: invocation_outcome()
  defp return_invocation_core(core, state), do: {:returned, state, core.()}

  @spec invoke_override_callback(atom(), atom(), function(), map()) :: invocation_outcome()
  defp invoke_override_callback(table, command, override_fun, state) do
    run_invocation_callback(table, :override, command, override_fun, state, fn ->
      override_fun.(state)
    end)
  end

  @spec run_invocation_core(map(), (map() -> invocation_outcome())) :: invocation_outcome()
  defp run_invocation_core(state, core), do: core.(state)

  @spec run_invocation_after_chain(invocation_outcome(), atom(), [state_fun()], atom()) ::
          invocation_outcome()
  defp run_invocation_after_chain({:returned, state, result}, table, afters, command) do
    {:returned, run_invocation_state_chain(state, table, afters, :after, command), result}
  end

  defp run_invocation_after_chain({:skipped, state}, table, afters, command) do
    {:skipped, run_invocation_state_chain(state, table, afters, :after, command)}
  end

  @spec run_invocation_state_chain(map(), atom(), [state_fun()], phase(), atom()) :: map()
  defp run_invocation_state_chain(state, _table, [], _phase, _command), do: state

  defp run_invocation_state_chain(state, table, funs, phase, command) do
    Enum.reduce(funs, state, fn fun, current_state ->
      run_invocation_state_callback(table, phase, command, fun, current_state)
    end)
  end

  @spec run_invocation_state_callback(atom(), phase(), atom(), state_fun(), map()) :: map()
  defp run_invocation_state_callback(table, phase, command, fun, state) do
    cb_key = {:cb_disabled, phase, command, fun}

    if cb_disabled?(table, cb_key) do
      state
    else
      invoke_state_callback(table, phase, command, fun, state)
    end
  end

  @spec invoke_state_callback(atom(), phase(), atom(), state_fun(), map()) :: map()
  defp invoke_state_callback(table, phase, command, fun, state) do
    case fun.(state) do
      next_state when is_map(next_state) ->
        reset_failures(table, phase, command, fun)
        next_state

      invalid ->
        record_invalid_invocation_result(table, phase, command, fun, invalid)
        state
    end
  rescue
    e ->
      record_invocation_failure(table, phase, command, fun, Exception.message(e))
      state
  catch
    kind, reason ->
      record_invocation_crash(table, phase, command, fun, kind, reason)
      state
  end

  @spec run_invocation_callback(atom(), phase(), atom(), function(), map(), (-> term())) ::
          invocation_outcome()
  defp run_invocation_callback(table, phase, command, fun, state, callback) do
    case normalize_invocation_outcome(callback.()) do
      {:ok, outcome} ->
        reset_failures(table, phase, command, fun)
        outcome

      {:error, invalid} ->
        record_invalid_invocation_result(table, phase, command, fun, invalid)
        {:skipped, state}
    end
  rescue
    e ->
      record_invocation_failure(table, phase, command, fun, Exception.message(e))
      {:skipped, state}
  catch
    kind, reason ->
      record_invocation_crash(table, phase, command, fun, kind, reason)
      {:skipped, state}
  end

  @spec normalize_invocation_outcome(term()) ::
          {:ok, invocation_outcome()} | {:error, term()}
  defp normalize_invocation_outcome({:returned, state, result}) when is_map(state),
    do: {:ok, {:returned, state, result}}

  defp normalize_invocation_outcome({:skipped, state}) when is_map(state),
    do: {:ok, {:skipped, state}}

  defp normalize_invocation_outcome(state) when is_map(state), do: {:ok, {:skipped, state}}
  defp normalize_invocation_outcome(invalid), do: {:error, invalid}

  @spec record_invalid_invocation_result(atom(), phase(), atom(), function(), term()) :: :ok
  defp record_invalid_invocation_result(table, phase, command, fun, invalid) do
    record_failure(table, phase, command, fun)

    Minga.Log.warning(
      :config,
      "Advice #{phase}:#{command} returned an invalid invocation value: #{inspect(invalid)}"
    )
  end

  @spec record_invocation_failure(atom(), phase(), atom(), function(), String.t()) :: :ok
  defp record_invocation_failure(table, phase, command, fun, message) do
    record_failure(table, phase, command, fun)
    Minga.Log.warning(:config, "Advice #{phase}:#{command} failed: #{message}")
  end

  @spec record_invocation_crash(atom(), phase(), atom(), function(), term(), term()) :: :ok
  defp record_invocation_crash(table, phase, command, fun, kind, reason) do
    record_failure(table, phase, command, fun)

    Minga.Log.warning(
      :config,
      "Advice #{phase}:#{command} crashed: #{inspect(kind)} #{inspect(reason)}"
    )
  end

  # Builds the core function: override replaces execute, around wraps it.
  # If both are present, arounds wrap the override.
  @spec build_core((map() -> map()), [state_fun()], [around_fun()]) :: (map() -> map())
  defp build_core(execute, [], []), do: execute

  defp build_core(_execute, overrides, []) do
    # Last override wins (innermost)
    Enum.at(overrides, -1)
  end

  defp build_core(execute, overrides, arounds) do
    base =
      case overrides do
        [] -> execute
        _ -> Enum.at(overrides, -1)
      end

    # Arounds nest: first registered is outermost
    Enum.reduce(Enum.reverse(arounds), base, fn around_fn, inner ->
      fn state -> around_fn.(inner, state) end
    end)
  end

  @spec run_chain(map(), atom(), [state_fun()], phase(), atom()) :: map()
  defp run_chain(state, _table, [], _phase, _command), do: state

  defp run_chain(state, table, funs, phase, command) do
    Enum.reduce(funs, state, fn fun, acc ->
      cb_key = {:cb_disabled, phase, command, fun}

      if cb_disabled?(table, cb_key) do
        acc
      else
        try do
          result = fun.(acc)
          reset_failures(table, phase, command, fun)
          result
        rescue
          e ->
            record_failure(table, phase, command, fun)

            Minga.Log.warning(
              :config,
              "Advice #{phase}:#{command} failed: #{Exception.message(e)}"
            )

            acc
        catch
          kind, reason ->
            record_failure(table, phase, command, fun)

            Minga.Log.warning(
              :config,
              "Advice #{phase}:#{command} crashed: #{inspect(kind)} #{inspect(reason)}"
            )

            acc
        end
      end
    end)
  end

  @spec cb_disabled?(atom(), tuple()) :: boolean()
  defp cb_disabled?(table, cb_key) do
    case :ets.lookup(table, cb_key) do
      [{_, true}] -> true
      _ -> false
    end
  end

  @spec record_failure(atom(), phase(), atom(), function()) :: :ok
  defp record_failure(table, phase, command, fun) do
    failures_key = {:cb_failures, phase, command, fun}

    count =
      case :ets.lookup(table, failures_key) do
        [{_, n}] -> n + 1
        [] -> 1
      end

    :ets.insert(table, {failures_key, count})

    if count >= @circuit_breaker_threshold do
      :ets.insert(table, {{:cb_disabled, phase, command, fun}, true})
      source = identify_source(fun)

      Minga.Log.warning(
        :config,
        "Advice #{phase}:#{command} disabled after #{count} consecutive failures#{source}"
      )
    end

    :ok
  end

  @spec reset_failures(atom(), phase(), atom(), function()) :: :ok
  defp reset_failures(table, phase, command, fun) do
    failures_key = {:cb_failures, phase, command, fun}

    case :ets.lookup(table, failures_key) do
      [{_, _}] -> :ets.delete(table, failures_key)
      [] -> :ok
    end

    :ok
  end

  @spec identify_source(function()) :: String.t()
  defp identify_source(fun) do
    case Function.info(fun, :module) do
      {:module, :erl_eval} -> ""
      {:module, mod} -> source_label(inspect(mod))
      _ -> ""
    end
  end

  @spec source_label(String.t()) :: String.t()
  defp source_label(""), do: ""

  defp source_label(mod_str) do
    if String.contains?(mod_str, "minga_org") do
      " (source: minga_org)"
    else
      " (source: #{mod_str})"
    end
  end

  @spec run_core(map(), (map() -> map()), atom()) :: map()
  defp run_core(state, core, command) do
    core.(state)
  rescue
    e ->
      Minga.Log.warning(:config, "Advice core for #{command} failed: #{Exception.message(e)}")
      state
  catch
    kind, reason ->
      Minga.Log.warning(
        :config,
        "Advice core for #{command} crashed: #{inspect(kind)} #{inspect(reason)}"
      )

      state
  end

  # ── Internal GenServer (table owner) ────────────────────────────────────────

  defmodule Server do
    @moduledoc false
    use GenServer

    @impl true
    @spec init(keyword()) :: {:ok, atom()}
    def init(opts) do
      table = Keyword.get(opts, :name, Minga.Config.Advice)

      :ets.new(table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

      {:ok, table}
    end
  end
end
