defmodule MingaAgent.Hooks.RecordingHook do
  @moduledoc false

  @key {__MODULE__, :pid}

  @spec set_recipient(pid()) :: :ok
  def set_recipient(pid) when is_pid(pid) do
    :persistent_term.put(@key, pid)
    :ok
  end

  @spec clear_recipient() :: :ok
  def clear_recipient do
    :persistent_term.erase(@key)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @spec record(map()) :: :allow
  def record(payload) when is_map(payload) do
    case :persistent_term.get(@key, nil) do
      pid when is_pid(pid) -> send(pid, {:agent_hook_payload, payload})
      nil -> :ok
    end

    :allow
  end
end
