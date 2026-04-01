defmodule MingaAgent.Tool.Executor do
  @moduledoc """
  Executes agent tools through the registry with approval checking and
  Config.Advice integration.

  The execution pipeline:

  1. Look up the tool spec in `MingaAgent.Tool.Registry`
  2. Check the tool's approval level (`:auto`, `:ask`, `:deny`)
  3. If `Minga.Config.Advice` has advice for the tool name (as an atom),
     wrap the execution through the advice chain
  4. Execute the tool callback in the calling process (no spawning)
  5. Return `{:ok, result}` or `{:error, reason}`

  ## ETS fast-path

  The advice check is a single ETS read via `Minga.Config.Advice.advised?/1`.
  When no advice is registered (the common case), the wrap is skipped
  entirely and the callback runs directly.

  ## Approval

  Tools with `:auto` approval execute immediately. Tools with `:deny`
  are rejected. Tools with `:ask` return `{:needs_approval, spec}` so
  the caller (typically `Agent.Session`) can request user confirmation
  before calling `execute_approved/2`.
  """

  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

  @typedoc "Result of tool execution."
  @type result :: {:ok, term()} | {:error, term()} | {:needs_approval, Spec.t(), map()}

  @doc """
  Executes a tool by name with the given arguments.

  Looks up the spec in the registry, checks approval, optionally wraps
  through Config.Advice, and runs the callback. Returns `{:ok, result}`,
  `{:error, reason}`, or `{:needs_approval, spec, args}` for tools
  that require user confirmation.

  The optional third argument is the registry table name (for testing).
  """
  @spec execute(String.t(), map()) :: result()
  def execute(name, args) when is_binary(name) and is_map(args) do
    execute(name, args, MingaAgent.Tool.Registry)
  end

  @spec execute(String.t(), map(), atom()) :: result()
  def execute(name, args, registry_table)
      when is_binary(name) and is_map(args) and is_atom(registry_table) do
    case Registry.lookup(registry_table, name) do
      {:ok, spec} -> check_and_execute(spec, args)
      :error -> {:error, {:tool_not_found, name}}
    end
  end

  @doc """
  Executes a tool that has already been approved by the user.

  Skips the approval check and runs the callback directly (with
  advice wrapping if applicable). Use this after receiving
  `{:needs_approval, spec, args}` from `execute/2` and getting
  user confirmation.
  """
  @spec execute_approved(Spec.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute_approved(%Spec{} = spec, args) when is_map(args) do
    run_callback(spec, args)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec check_and_execute(Spec.t(), map()) :: result()
  defp check_and_execute(%Spec{approval_level: :deny} = spec, _args) do
    {:error, {:tool_denied, spec.name}}
  end

  defp check_and_execute(%Spec{approval_level: :ask} = spec, args) do
    {:needs_approval, spec, args}
  end

  defp check_and_execute(%Spec{approval_level: :auto} = spec, args) do
    run_callback(spec, args)
  end

  @spec run_callback(Spec.t(), map()) :: {:ok, term()} | {:error, term()}
  defp run_callback(%Spec{} = spec, args) do
    tool_atom = String.to_existing_atom(spec.name)
    execute_with_advice(spec, args, tool_atom)
  rescue
    ArgumentError ->
      # Atom doesn't exist yet; no advice can be registered for it.
      execute_raw(spec, args)
  end

  @spec execute_with_advice(Spec.t(), map(), atom()) :: {:ok, term()} | {:error, term()}
  defp execute_with_advice(spec, args, tool_atom) do
    if advice_available?() and Minga.Config.Advice.advised?(tool_atom) do
      # Advice wraps a (state -> state) function. For tools, the "state"
      # is the args map and the "result" is the callback return value.
      # We wrap the callback in a function that the advice chain can
      # intercept, storing the result in the process dictionary since
      # advice expects state-in/state-out.
      wrapped =
        Minga.Config.Advice.wrap(tool_atom, fn _state ->
          result = spec.callback.(args)
          Process.put(:__tool_result__, result)
          args
        end)

      wrapped.(args)
      result = Process.delete(:__tool_result__)
      normalize_result(result)
    else
      execute_raw(spec, args)
    end
  end

  @spec execute_raw(Spec.t(), map()) :: {:ok, term()} | {:error, term()}
  defp execute_raw(%Spec{} = spec, args) do
    result = spec.callback.(args)
    normalize_result(result)
  rescue
    e ->
      Minga.Log.warning(:agent, "Tool #{spec.name} raised: #{Exception.message(e)}")
      {:error, {:raised, Exception.message(e)}}
  catch
    kind, reason ->
      Minga.Log.warning(:agent, "Tool #{spec.name} crashed: #{inspect(kind)} #{inspect(reason)}")
      {:error, {:crashed, {kind, reason}}}
  end

  @spec normalize_result(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_result({:ok, _} = ok), do: ok
  defp normalize_result({:error, _} = err), do: err
  defp normalize_result(nil), do: {:error, :no_result}
  defp normalize_result(other), do: {:ok, other}

  @spec advice_available?() :: boolean()
  defp advice_available? do
    :ets.whereis(Minga.Config.Advice) != :undefined
  rescue
    # :ets.whereis/1 was added in OTP 21; fallback for safety
    ArgumentError -> false
  end
end
