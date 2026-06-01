defmodule MingaAgent.Tool.Executor do
  @moduledoc """
  Executes agent tools through the registry with approval checking, context validation, and Config.Advice integration.
  """

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Hooks.CommandRunner
  alias MingaAgent.Hooks.Dispatcher, as: HookDispatcher
  alias MingaAgent.Hooks.PostToolUsePayload
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result, as: HookResult
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.PlanMode
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

  @typedoc "Result of tool execution."
  @type result :: {:ok, term()} | {:error, term()} | {:needs_approval, Spec.t(), map()}
  @type hook_runner :: (MingaAgent.Hooks.Hook.t(), PreToolUsePayload.t() -> HookResult.t())

  @typedoc "Execution mode: `:exec` allows all tools, `:plan` refuses destructive tools before approval."
  @type execution_mode :: :exec | :plan

  @doc "Executes a tool by name with the given arguments."
  @spec execute(String.t(), map()) :: result()
  def execute(name, args) when is_binary(name) and is_map(args) do
    execute(name, args, Registry, :exec, [])
  end

  @spec execute(String.t(), map(), atom()) :: result()
  def execute(name, args, registry_table)
      when is_binary(name) and is_map(args) and is_atom(registry_table) do
    execute(name, args, registry_table, :exec, [])
  end

  @spec execute(String.t(), map(), atom(), execution_mode()) :: result()
  def execute(name, args, registry_table, mode)
      when is_binary(name) and is_map(args) and is_atom(registry_table) and mode in [:exec, :plan] do
    execute(name, args, registry_table, mode, [])
  end

  @doc false
  @spec execute(String.t(), map(), atom(), execution_mode(), keyword()) :: result()
  def execute(name, args, registry_table, mode, opts)
      when is_binary(name) and is_map(args) and is_atom(registry_table) and mode in [:exec, :plan] and
             is_list(opts) do
    config = Keyword.get_lazy(opts, :config, &AgentConfig.resolve/0)
    hook_runner = Keyword.get(opts, :hook_runner, &CommandRunner.run_pre_tool_use/2)
    tool_context = Keyword.get(opts, :tool_context)

    case Registry.lookup(registry_table, name) do
      {:ok, spec} -> check_and_execute(spec, args, mode, config, hook_runner, tool_context)
      :error -> {:error, {:tool_not_found, name}}
    end
  end

  @doc "Executes a tool that has already been approved by the user."
  @spec execute_approved(Spec.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute_approved(%Spec{} = spec, args) when is_map(args) do
    execute_approved(spec, args, :exec, [])
  end

  @doc "Executes an approved tool with opts such as `:tool_context`."
  @spec execute_approved(Spec.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute_approved(%Spec{} = spec, args, opts) when is_map(args) and is_list(opts) do
    execute_approved(spec, args, :exec, opts)
  end

  @spec execute_approved(Spec.t(), map(), execution_mode()) :: {:ok, term()} | {:error, term()}
  def execute_approved(%Spec{} = spec, args, mode) when is_map(args) and mode in [:exec, :plan] do
    execute_approved(spec, args, mode, [])
  end

  @doc false
  @spec execute_approved(Spec.t(), map(), execution_mode(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_approved(%Spec{} = spec, args, mode, opts)
      when is_map(args) and mode in [:exec, :plan] and is_list(opts) do
    if plan_mode_blocked?(mode, spec.name, args) do
      {:error, PlanMode.refusal(spec.name)}
    else
      config = Keyword.get_lazy(opts, :config, &AgentConfig.resolve/0)
      hook_runner = Keyword.get(opts, :hook_runner, &CommandRunner.run_pre_tool_use/2)
      tool_context = Keyword.get(opts, :tool_context)

      with :ok <- ensure_context_available(spec, tool_context) do
        run_callback(spec, args, config, hook_runner, tool_context)
      end
    end
  end

  @spec check_and_execute(
          Spec.t(),
          map(),
          execution_mode(),
          AgentConfig.t(),
          hook_runner(),
          Context.t() | nil
        ) :: result()
  defp check_and_execute(%Spec{} = spec, args, :plan, config, hook_runner, tool_context) do
    if plan_mode_blocked?(:plan, spec.name, args) do
      {:error, PlanMode.refusal(spec.name)}
    else
      check_and_execute(spec, args, :exec, config, hook_runner, tool_context)
    end
  end

  defp check_and_execute(%Spec{} = spec, args, :exec, config, hook_runner, tool_context) do
    with :ok <- ensure_context_available(spec, tool_context) do
      check_approval_and_execute(spec, args, config, hook_runner, tool_context)
    end
  end

  @spec check_approval_and_execute(
          Spec.t(),
          map(),
          AgentConfig.t(),
          hook_runner(),
          Context.t() | nil
        ) :: result()
  defp check_approval_and_execute(
         %Spec{approval_level: :deny} = spec,
         _args,
         _config,
         _hook_runner,
         _tool_context
       ) do
    {:error, {:tool_denied, spec.name}}
  end

  defp check_approval_and_execute(
         %Spec{approval_level: :ask} = spec,
         args,
         _config,
         _hook_runner,
         _tool_context
       ) do
    {:needs_approval, spec, args}
  end

  defp check_approval_and_execute(
         %Spec{approval_level: :auto} = spec,
         args,
         config,
         hook_runner,
         tool_context
       ) do
    run_callback(spec, args, config, hook_runner, tool_context)
  end

  @spec ensure_context_available(Spec.t(), Context.t() | nil) :: :ok | {:error, term()}
  defp ensure_context_available(%Spec{context_requirements: requirements, name: name}, nil) do
    if :tool_context in requirements do
      {:error, {:missing_tool_context, name, requirements}}
    else
      :ok
    end
  end

  defp ensure_context_available(%Spec{}, %Context{}), do: :ok

  @spec plan_mode_blocked?(execution_mode(), String.t(), map()) :: boolean()
  defp plan_mode_blocked?(:plan, name, args), do: PlanMode.blocked?(name, args)
  defp plan_mode_blocked?(:exec, _name, _args), do: false

  @spec run_callback(Spec.t(), map(), AgentConfig.t(), hook_runner(), Context.t() | nil) ::
          {:ok, term()} | {:error, term()}
  defp run_callback(%Spec{} = spec, args, config, hook_runner, tool_context) do
    case dispatch_pre_tool_use(spec, args, config, hook_runner) do
      :ok ->
        result = run_callback_with_advice(spec, args, tool_context)
        dispatch_post_tool_use(spec, args, result, config)
        result

      {:error, %HookResult{} = result} ->
        {:error, {:hook_veto, HookResult.message(result)}}
    end
  end

  @spec run_callback_with_advice(Spec.t(), map(), Context.t() | nil) ::
          {:ok, term()} | {:error, term()}
  defp run_callback_with_advice(%Spec{} = spec, args, tool_context) do
    tool_atom = String.to_existing_atom(spec.name)
    execute_with_advice(spec, args, tool_atom, tool_context)
  rescue
    ArgumentError -> execute_raw(spec, args, tool_context)
  end

  @spec dispatch_pre_tool_use(Spec.t(), map(), AgentConfig.t(), hook_runner()) ::
          :ok | {:error, HookResult.t()}
  defp dispatch_pre_tool_use(%Spec{} = spec, args, config, hook_runner) do
    payload =
      PreToolUsePayload.new("direct_#{:erlang.unique_integer([:positive])}", spec.name, args)

    HookDispatcher.pre_tool_use(config.agent_hooks, payload, runner: hook_runner)
  end

  @spec dispatch_post_tool_use(Spec.t(), map(), {:ok, term()} | {:error, term()}, AgentConfig.t()) ::
          :ok
  defp dispatch_post_tool_use(%Spec{} = spec, args, result, config) do
    {result_text, is_error} =
      case result do
        {:ok, value} -> {inspect(value), false}
        {:error, reason} -> {inspect(reason), true}
      end

    payload =
      PostToolUsePayload.new(
        "direct_#{:erlang.unique_integer([:positive])}",
        spec.name,
        args,
        result_text,
        is_error
      )

    HookDispatcher.post_tool_use(config.agent_hooks, PostToolUsePayload.to_map(payload))
  rescue
    e -> Minga.Log.warning(:agent, "PostToolUse hook dispatch failed: #{Exception.message(e)}")
  catch
    _, reason -> Minga.Log.warning(:agent, "PostToolUse hook dispatch failed: #{inspect(reason)}")
  end

  @spec execute_with_advice(Spec.t(), map(), atom(), Context.t() | nil) ::
          {:ok, term()} | {:error, term()}
  defp execute_with_advice(spec, args, tool_atom, tool_context) do
    if advice_available?() and Minga.Config.Advice.advised?(tool_atom) do
      wrapped =
        Minga.Config.Advice.wrap(tool_atom, fn _state ->
          callback = Spec.build_callback(spec, tool_context)
          result = callback.(args)
          Process.put(:__tool_result__, result)
          args
        end)

      wrapped.(args)
      result = Process.delete(:__tool_result__)
      normalize_result(result)
    else
      execute_raw(spec, args, tool_context)
    end
  end

  @spec execute_raw(Spec.t(), map(), Context.t() | nil) :: {:ok, term()} | {:error, term()}
  defp execute_raw(%Spec{} = spec, args, tool_context) do
    callback = Spec.build_callback(spec, tool_context)
    result = callback.(args)
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
    ArgumentError -> false
  end
end
