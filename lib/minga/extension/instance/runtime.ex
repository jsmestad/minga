defmodule Minga.Extension.Instance.Runtime do
  @moduledoc "Monitored runtime identity owned by an extension Instance."

  @enforce_keys [:pid, :monitor]
  defstruct [:pid, :monitor]

  @type t :: %__MODULE__{pid: pid(), monitor: reference()}

  @doc "Monitors and captures a runtime process."
  @spec monitor(pid()) :: t()
  def monitor(pid) when is_pid(pid), do: %__MODULE__{pid: pid, monitor: Process.monitor(pid)}

  @doc "Returns the existing identity when it already names the process, otherwise monitors it."
  @spec ensure(t() | nil, pid()) :: t()
  def ensure(%__MODULE__{pid: pid} = runtime, pid), do: runtime
  def ensure(_runtime, pid), do: monitor(pid)

  @doc "Reports whether a DOWN identity matches this runtime."
  @spec matches?(t(), reference(), pid()) :: boolean()
  def matches?(%__MODULE__{pid: pid, monitor: monitor}, monitor, pid), do: true
  def matches?(%__MODULE__{}, _monitor, _pid), do: false

  @doc "Drops this runtime's monitor and any queued DOWN message."
  @spec demonitor(t() | nil) :: :ok
  def demonitor(nil), do: :ok

  def demonitor(%__MODULE__{monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    :ok
  end
end
