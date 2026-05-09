defmodule MingaAgent.Hooks.Dispatcher do
  @moduledoc """
  Dispatches normalized agent hooks for a tool lifecycle event.

  The dispatcher is intentionally stateless. It receives a list of hooks from
  `MingaAgent.Config`, filters matching hooks in registration order, and asks a
  runner to execute each hook. The first veto short-circuits later hooks.
  """

  alias Minga.Events
  alias MingaAgent.Hooks.CommandRunner
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result

  @typedoc "Hook runner used by tests and production command execution."
  @type runner :: (Hook.t(), PreToolUsePayload.t() -> Result.t())

  @doc "Runs all matching `PreToolUse` hooks in registration order."
  @spec pre_tool_use([Hook.t()], PreToolUsePayload.t()) :: :ok | {:error, Result.t()}
  def pre_tool_use(hooks, %PreToolUsePayload{} = payload) when is_list(hooks) do
    pre_tool_use(hooks, payload, [])
  end

  @doc "Runs matching `PreToolUse` hooks with an injected runner."
  @spec pre_tool_use([Hook.t()], PreToolUsePayload.t(), keyword()) :: :ok | {:error, Result.t()}
  def pre_tool_use(hooks, %PreToolUsePayload{} = payload, opts)
      when is_list(hooks) and is_list(opts) do
    runner = Keyword.get(opts, :runner, &CommandRunner.run_pre_tool_use/2)

    hooks
    |> Enum.filter(&Hook.matches?(&1, :pre_tool_use, payload.tool_name))
    |> run_matching_hooks(payload, runner)
  end

  @spec run_matching_hooks([Hook.t()], PreToolUsePayload.t(), runner()) ::
          :ok | {:error, Result.t()}
  defp run_matching_hooks([], _payload, _runner), do: :ok

  defp run_matching_hooks([hook | rest], payload, runner) do
    broadcast(:started, hook, payload, nil)

    case runner.(hook, payload) do
      %Result{status: :allow} = result ->
        broadcast(:allowed, hook, payload, result)
        run_matching_hooks(rest, payload, runner)

      %Result{status: :veto} = result ->
        broadcast(:vetoed, hook, payload, result)
        {:error, result}
    end
  end

  @spec broadcast(
          :started | :allowed | :vetoed,
          Hook.t(),
          PreToolUsePayload.t(),
          Result.t() | nil
        ) :: :ok
  defp broadcast(phase, hook, payload, result) do
    Events.broadcast(:agent_hook, %Events.AgentHookEvent{
      event: "PreToolUse",
      phase: phase,
      tool_name: payload.tool_name,
      tool_call_id: payload.tool_call_id,
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
