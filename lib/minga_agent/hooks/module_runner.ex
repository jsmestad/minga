defmodule MingaAgent.Hooks.ModuleRunner do
  @moduledoc """
  Executes Elixir-module hooks in a monitored process with timeout enforcement.

  Module hooks receive the payload map as a single argument and return
  `:allow` or `{:veto, reason}`. The hook runs in a spawned process
  (not linked) so crashes don't propagate to the caller.
  """

  alias Minga.Extension.CodeLease
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.Result

  @doc "Runs a module hook with a payload map."
  @spec run(Hook.t(), map()) :: Result.t()
  def run(%Hook{type: :module, module: mod, function: fun} = hook, payload_map)
      when is_atom(mod) and is_atom(fun) and is_map(payload_map) do
    caller = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        result = run_leased_module_hook(hook, mod, fun, payload_map)
        send(caller, {tag, result})
      end)

    receive do
      {^tag, :allow} ->
        flush_down(ref)
        Result.allow(hook)

      {^tag, {:veto, reason}} when is_binary(reason) ->
        flush_down(ref)
        Result.veto(hook, reason, {:exit, 1})

      {^tag, other} ->
        flush_down(ref)

        Result.veto(
          hook,
          "module hook returned unexpected value: #{inspect(other)}",
          {:failed_to_start, :bad_return}
        )

      {:DOWN, ^ref, :process, ^pid, :normal} ->
        Result.veto(
          hook,
          "module hook exited without responding",
          {:failed_to_start, :no_response}
        )

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Result.veto(
          hook,
          "module hook crashed: #{format_crash(reason)}",
          {:failed_to_start, reason}
        )
    after
      hook.timeout_ms ->
        Process.exit(pid, :kill)
        flush_down(ref)

        Result.veto(
          hook,
          "#{Hook.event_label(hook.event)} module hook timed out after #{hook.timeout_ms}ms",
          :timeout
        )
    end
  rescue
    e ->
      Result.veto(
        hook,
        "module hook raised: #{Exception.message(e)}",
        {:failed_to_start, e}
      )
  end

  @spec run_leased_module_hook(Hook.t(), module(), atom(), map()) :: term()
  defp run_leased_module_hook(%Hook{extension_source: nil}, mod, fun, payload_map) do
    apply(mod, fun, [payload_map])
  end

  defp run_leased_module_hook(%Hook{extension_source: source}, mod, fun, payload_map)
       when is_atom(source) do
    case CodeLease.lease({:extension, source}, mod, :hook) do
      {:ok, lease} ->
        try do
          apply(mod, fun, [payload_map])
        after
          CodeLease.release(lease)
        end

      {:error, reason} ->
        raise "extension #{source} hook module #{inspect(mod)} unavailable: #{inspect(reason)}"
    end
  end

  @spec flush_down(reference()) :: :ok
  defp flush_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      0 -> :ok
    end
  end

  @spec format_crash(term()) :: String.t()
  defp format_crash({exception, _stacktrace}) when is_exception(exception) do
    Exception.message(exception)
  end

  defp format_crash(reason), do: inspect(reason)
end
