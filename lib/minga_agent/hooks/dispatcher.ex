defmodule MingaAgent.Hooks.Dispatcher do
  @moduledoc """
  Dispatches normalized agent hooks for lifecycle events.

  The dispatcher is intentionally stateless. It receives a list of hooks from
  `MingaAgent.Config`, filters matching hooks in registration order, and asks a
  runner to execute each hook. For veto-capable events the first veto
  short-circuits later hooks; for notification-only events vetoes are logged
  but do not block.
  """

  alias Minga.Events
  alias MingaAgent.Hooks.CommandRunner
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.ModuleRunner
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result

  @typedoc "Hook runner used by tests and production command execution."
  @type runner :: (Hook.t(), map() -> Result.t())

  @doc "Runs all matching hooks for an event in registration order."
  @spec dispatch(Hook.event(), [Hook.t()], map(), keyword()) :: :ok | {:error, Result.t()}
  def dispatch(event, hooks, payload_map, opts \\ [])
      when is_atom(event) and is_list(hooks) and is_map(payload_map) and is_list(opts) do
    runner_override = Keyword.get(opts, :runner)
    veto_capable = Keyword.get(opts, :veto_capable, true)
    tool_name = Map.get(payload_map, "tool_name")

    matching =
      if Hook.tool_event?(event) and is_binary(tool_name) do
        Enum.filter(hooks, &Hook.matches?(&1, event, tool_name))
      else
        Enum.filter(hooks, &Hook.matches?(&1, event))
      end

    run_matching_hooks(matching, event, payload_map, runner_override, veto_capable)
  end

  @doc "Runs all matching `PreToolUse` hooks in registration order."
  @spec pre_tool_use([Hook.t()], PreToolUsePayload.t()) :: :ok | {:error, Result.t()}
  def pre_tool_use(hooks, %PreToolUsePayload{} = payload) when is_list(hooks) do
    pre_tool_use(hooks, payload, [])
  end

  @doc "Runs matching `PreToolUse` hooks with an injected runner."
  @spec pre_tool_use([Hook.t()], PreToolUsePayload.t(), keyword()) :: :ok | {:error, Result.t()}
  def pre_tool_use(hooks, %PreToolUsePayload{} = payload, opts)
      when is_list(hooks) and is_list(opts) do
    legacy_runner = Keyword.get(opts, :runner)

    runner =
      if legacy_runner do
        fn hook, payload_map -> legacy_runner.(hook, PreToolUsePayload.new(payload_map)) end
      else
        nil
      end

    dispatch_opts =
      if runner, do: [runner: runner, veto_capable: true], else: [veto_capable: true]

    dispatch(:pre_tool_use, hooks, PreToolUsePayload.to_map(payload), dispatch_opts)
  end

  @doc "Runs all matching `PostToolUse` hooks (notification-only)."
  @spec post_tool_use([Hook.t()], map()) :: :ok
  @spec post_tool_use([Hook.t()], map(), keyword()) :: :ok
  def post_tool_use(hooks, payload_map, opts \\ [])
      when is_list(hooks) and is_map(payload_map) do
    dispatch(:post_tool_use, hooks, payload_map, Keyword.put(opts, :veto_capable, false))
    :ok
  end

  @doc "Runs all matching `SessionStart` hooks (notification-only)."
  @spec session_start([Hook.t()], map()) :: :ok
  @spec session_start([Hook.t()], map(), keyword()) :: :ok
  def session_start(hooks, payload_map, opts \\ [])
      when is_list(hooks) and is_map(payload_map) do
    dispatch(:session_start, hooks, payload_map, Keyword.put(opts, :veto_capable, false))
    :ok
  end

  @doc "Runs all matching `SessionEnd` hooks (notification-only)."
  @spec session_end([Hook.t()], map()) :: :ok
  @spec session_end([Hook.t()], map(), keyword()) :: :ok
  def session_end(hooks, payload_map, opts \\ [])
      when is_list(hooks) and is_map(payload_map) do
    dispatch(:session_end, hooks, payload_map, Keyword.put(opts, :veto_capable, false))
    :ok
  end

  @doc "Runs all matching `Stop` hooks (notification-only)."
  @spec stop([Hook.t()], map()) :: :ok
  @spec stop([Hook.t()], map(), keyword()) :: :ok
  def stop(hooks, payload_map, opts \\ [])
      when is_list(hooks) and is_map(payload_map) do
    dispatch(:stop, hooks, payload_map, Keyword.put(opts, :veto_capable, false))
    :ok
  end

  @doc "Runs all matching `UserPromptSubmit` hooks (veto-capable)."
  @spec user_prompt_submit([Hook.t()], map()) :: :ok | {:error, Result.t()}
  @spec user_prompt_submit([Hook.t()], map(), keyword()) :: :ok | {:error, Result.t()}
  def user_prompt_submit(hooks, payload_map, opts \\ [])
      when is_list(hooks) and is_map(payload_map) do
    dispatch(:user_prompt_submit, hooks, payload_map, Keyword.put(opts, :veto_capable, true))
  end

  @doc "Runs all matching `PreCompact` hooks (veto-capable)."
  @spec pre_compact([Hook.t()], map()) :: :ok | {:error, Result.t()}
  @spec pre_compact([Hook.t()], map(), keyword()) :: :ok | {:error, Result.t()}
  def pre_compact(hooks, payload_map, opts \\ [])
      when is_list(hooks) and is_map(payload_map) do
    dispatch(:pre_compact, hooks, payload_map, Keyword.put(opts, :veto_capable, true))
  end

  @doc "Runs all matching `Notification` hooks (notification-only)."
  @spec notification([Hook.t()], map()) :: :ok
  @spec notification([Hook.t()], map(), keyword()) :: :ok
  def notification(hooks, payload_map, opts \\ [])
      when is_list(hooks) and is_map(payload_map) do
    dispatch(:notification, hooks, payload_map, Keyword.put(opts, :veto_capable, false))
    :ok
  end

  @spec run_matching_hooks([Hook.t()], Hook.event(), map(), runner() | nil, boolean()) ::
          :ok | {:error, Result.t()}
  defp run_matching_hooks([], _event, _payload_map, _runner_override, _veto_capable), do: :ok

  defp run_matching_hooks([hook | rest], event, payload_map, runner_override, veto_capable) do
    runner = runner_override || runner_for_hook(hook)
    broadcast(:started, event, hook, payload_map, nil)

    case runner.(hook, payload_map) do
      %Result{status: :allow} = result ->
        broadcast(:allowed, event, hook, payload_map, result)
        run_matching_hooks(rest, event, payload_map, runner_override, veto_capable)

      %Result{status: :veto} = result ->
        broadcast(:vetoed, event, hook, payload_map, result)

        if veto_capable do
          {:error, result}
        else
          Minga.Log.warning(
            :agent,
            "#{Hook.event_label(event)} hook veto ignored (notification-only): #{Result.message(result)}"
          )

          run_matching_hooks(rest, event, payload_map, runner_override, veto_capable)
        end
    end
  end

  @spec runner_for_hook(Hook.t()) :: runner()
  defp runner_for_hook(%Hook{type: :module}), do: &ModuleRunner.run/2
  defp runner_for_hook(%Hook{}), do: &CommandRunner.run/2

  @spec broadcast(
          :started | :allowed | :vetoed,
          Hook.event(),
          Hook.t(),
          map(),
          Result.t() | nil
        ) :: :ok
  defp broadcast(phase, event, hook, payload_map, result) do
    Events.broadcast(:agent_hook, %Events.AgentHookEvent{
      event: Hook.event_label(event),
      phase: phase,
      tool_name: Map.get(payload_map, "tool_name"),
      tool_call_id: Map.get(payload_map, "tool_call_id"),
      tool_pattern: hook.tool_pattern,
      exit_status: if(result, do: result.exit_status, else: nil),
      reason: if(result, do: result.reason, else: nil)
    })
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end
end
