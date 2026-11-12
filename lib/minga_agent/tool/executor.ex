defmodule MingaAgent.Tool.Executor do
  @moduledoc "Executes current declarations only after hooks, advice, and final live admission."

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Hooks.CommandRunner
  alias MingaAgent.Hooks.Dispatcher, as: HookDispatcher
  alias MingaAgent.Hooks.PostToolUsePayload
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result, as: HookResult
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Invocation
  alias MingaAgent.Tool.Limitation
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.PlanMode
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

  @type result ::
          {:ok, term()}
          | {:error, term()}
          | {:needs_approval, Spec.t(), map()}
          | {:storage_error, term()}
  @type execution_mode :: :exec | :plan
  @type hook_runner :: (MingaAgent.Hooks.Hook.t(), PreToolUsePayload.t() -> HookResult.t())

  @doc "Executes a current named tool; approval-required remains a non-executable outcome."
  @spec execute(String.t(), map()) :: result()
  def execute(name, args), do: execute(name, args, Registry, :exec, [])

  @spec execute(String.t(), map(), atom()) :: result()
  def execute(name, args, table), do: execute(name, args, table, :exec, [])

  @spec execute(String.t(), map(), atom(), execution_mode()) :: result()
  def execute(name, args, table, mode), do: execute(name, args, table, mode, [])

  @spec execute(String.t(), map(), atom(), execution_mode(), keyword()) :: result()
  def execute(name, args, table, mode, opts)
      when is_binary(name) and is_map(args) and is_atom(table) and mode in [:exec, :plan] do
    with {:ok, spec, registration} <- Registry.resolve_execution(table, name),
         :ok <- direct_authorization(spec, args, mode),
         :ok <- ensure_context_available(spec, Keyword.get(opts, :tool_context)) do
      once = :atomics.new(1, [])
      start = fn -> direct_start(table, name, registration, args, mode, opts, once) end
      run(name, args, start, opts)
    end
  end

  @doc "Executes a correlated Session invocation through its one-shot final-start owner."
  @spec execute_session(GenServer.server(), Invocation.t(), keyword()) :: result()
  def execute_session(session, %Invocation{} = invocation, opts) do
    start = fn ->
      case GenServer.call(session, {:start_tool_invocation, invocation}, 30_000) do
        {:ok, spec, store} ->
          context =
            Context.for_tool_call(
              Keyword.fetch!(opts, :tool_context),
              store,
              invocation.checkpoint_id,
              invocation.call_id
            )

          execute_current(spec, invocation.arguments, context)
          |> retain_session_result(context, session, invocation)

        {:refused, reason} ->
          {:error, {:tool_refused, reason}}

        {:error, reason} ->
          {:storage_error, {:effect_admission_failed, reason}}
      end
    end

    run(
      invocation.name,
      invocation.arguments,
      start,
      Keyword.put(opts, :tool_call_id, invocation.call_id)
    )
  end

  @spec direct_start(
          atom(),
          String.t(),
          reference(),
          map(),
          execution_mode(),
          keyword(),
          reference()
        ) :: result()
  defp direct_start(table, name, registration, args, mode, opts, once) do
    with :ok <- claim_once(once),
         {:ok, spec, ^registration} <- Registry.resolve_execution(table, name),
         :ok <- direct_authorization(spec, args, mode) do
      execute_current(spec, args, Keyword.get(opts, :tool_context))
    else
      {:ok, _replacement, _registration} -> {:error, :tool_declaration_changed}
      error -> error
    end
  end

  @spec claim_once(reference()) :: :ok | {:error, :duplicate_invocation}
  defp claim_once(once) do
    case :atomics.compare_exchange(once, 1, 0, 1) do
      :ok -> :ok
      _claimed -> {:error, :duplicate_invocation}
    end
  end

  @spec direct_authorization(Spec.t(), map(), execution_mode()) :: :ok | result()
  defp direct_authorization(spec, args, :plan) do
    if PlanMode.blocked?(spec.name, args),
      do: {:error, PlanMode.refusal(spec.name)},
      else: direct_authorization(spec, args, :exec)
  end

  defp direct_authorization(%Spec{approval_level: :deny, name: name}, _args, :exec),
    do: {:error, {:tool_denied, name}}

  defp direct_authorization(%Spec{approval_level: :ask} = spec, args, :exec),
    do: {:needs_approval, spec, args}

  defp direct_authorization(%Spec{approval_level: :auto}, _args, :exec), do: :ok

  @spec run(String.t(), map(), (-> result()), keyword()) :: result()
  defp run(name, args, start, opts) do
    config = Keyword.get_lazy(opts, :config, &AgentConfig.resolve/0)
    runner = Keyword.get(opts, :hook_runner, &CommandRunner.run_pre_tool_use/2)

    call_id =
      Keyword.get_lazy(opts, :tool_call_id, fn ->
        "direct_#{:erlang.unique_integer([:positive])}"
      end)

    payload = PreToolUsePayload.new(call_id, name, args)

    case HookDispatcher.pre_tool_use(config.agent_hooks, payload, runner: runner) do
      :ok ->
        result = invoke_advice(name, args, start)

        dispatch_post_hook(
          Keyword.get(opts, :dispatch_post_hook, true),
          config,
          call_id,
          name,
          args,
          result
        )

        result

      {:error, %HookResult{} = result} ->
        {:error, {:hook_veto, HookResult.message(result)}}
    end
  end

  @spec invoke_advice(String.t(), map(), (-> result())) :: result()
  defp invoke_advice(name, args, start) do
    case advice_name(name) do
      {:ok, tool_atom} ->
        case Minga.Config.Advice.invoke(tool_atom, args, start) do
          {:returned, _advice_state, result} -> normalize_result(result)
          {:skipped, _advice_state} -> {:error, :no_result}
        end

      :none ->
        start.()
    end
  end

  @spec advice_name(String.t()) :: {:ok, atom()} | :none
  defp advice_name(name) do
    tool_atom = String.to_existing_atom(name)

    if :ets.whereis(Minga.Config.Advice) != :undefined and Minga.Config.Advice.advised?(tool_atom),
      do: {:ok, tool_atom},
      else: :none
  rescue
    ArgumentError -> :none
  end

  @spec execute_current(Spec.t(), map(), Context.t() | nil) :: result()
  defp execute_current(%Spec{} = spec, args, context) do
    with :ok <- ensure_context_available(spec, context),
         {:ok, validated} <- Spec.validate_arguments(spec, args) do
      callback = Spec.build_callback(spec, context)
      normalize_result(callback.(validated))
    end
  rescue
    e ->
      Minga.Log.warning(:agent, "Tool #{spec.name} raised: #{Exception.message(e)}")
      {:error, {:raised, Exception.message(e)}}
  catch
    kind, reason ->
      Minga.Log.warning(:agent, "Tool #{spec.name} crashed: #{inspect(kind)} #{inspect(reason)}")
      {:error, {:crashed, {kind, reason}}}
  end

  @spec retain_session_result(result(), Context.t(), GenServer.server(), Invocation.t()) ::
          result()
  defp retain_session_result({status, %Output{}} = result, _context, _session, _invocation)
       when status in [:ok, :error], do: result

  defp retain_session_result({status, value}, context, session, invocation)
       when status in [:ok, :error] do
    text = result_text(value)

    captured =
      try do
        MingaAgent.Tools.OutputCapture.bytes(
          context.artifact_store,
          context.capture_key,
          text,
          []
        )
      catch
        :exit, reason -> {:error, {:retention_unavailable, reason}}
      end

    case captured do
      {:ok, output} ->
        {status, output}

      {:error, %Output{} = output} ->
        {:error, output}

      {:error, reason} ->
        GenServer.call(session, {:tool_storage_failed, invocation, reason})
        {:storage_error, {:retention_failed, reason}}
    end
  end

  @spec result_text(term()) :: String.t()
  defp result_text(value) when is_binary(value), do: value
  defp result_text(%Limitation{} = limitation), do: Limitation.message(limitation)
  defp result_text(%{__exception__: true} = error), do: Exception.message(error)
  defp result_text(value) when is_map(value) or is_list(value), do: JSON.encode!(value)
  defp result_text(value), do: inspect(value)

  @spec ensure_context_available(Spec.t(), Context.t() | nil) :: :ok | {:error, term()}
  defp ensure_context_available(%Spec{context_requirements: requirements, name: name}, nil) do
    if :tool_context in requirements,
      do: {:error, {:missing_tool_context, name, requirements}},
      else: :ok
  end

  defp ensure_context_available(%Spec{}, %Context{}), do: :ok

  @spec dispatch_post_hook(boolean(), AgentConfig.t(), String.t(), String.t(), map(), result()) ::
          :ok
  defp dispatch_post_hook(false, _config, _call_id, _name, _args, _result), do: :ok

  defp dispatch_post_hook(true, _config, _call_id, _name, _args, {:storage_error, _reason}),
    do: :ok

  defp dispatch_post_hook(true, config, call_id, name, args, result) do
    {text, is_error, output} = post_result(result)
    payload = PostToolUsePayload.new(call_id, name, args, text, is_error, output)
    HookDispatcher.post_tool_use(config.agent_hooks, PostToolUsePayload.to_map(payload))
  rescue
    e -> Minga.Log.warning(:agent, "PostToolUse hook dispatch failed: #{Exception.message(e)}")
  catch
    _, reason -> Minga.Log.warning(:agent, "PostToolUse hook dispatch failed: #{inspect(reason)}")
  end

  @spec post_result(result()) :: {String.t(), boolean(), Output.t() | nil}
  defp post_result({:ok, %Output{} = output}), do: {output.view, false, output}
  defp post_result({:error, %Output{} = output}), do: {output.view, true, output}

  defp post_result({:error, %Limitation{} = limitation}),
    do: {Limitation.message(limitation), true, nil}

  defp post_result({:ok, value}), do: {inspect(value), false, nil}
  defp post_result({:error, reason}), do: {inspect(reason), true, nil}
  defp post_result({:needs_approval, _spec, _args}), do: {"Approval is required", true, nil}

  @spec normalize_result(term()) :: result()
  defp normalize_result({:ok, _} = result), do: result
  defp normalize_result({:error, _} = result), do: result
  defp normalize_result({:needs_approval, _, _} = result), do: result
  defp normalize_result({:storage_error, _reason} = result), do: result
  defp normalize_result(nil), do: {:error, :no_result}
  defp normalize_result(value), do: {:ok, value}
end
