defmodule MingaAgent.ArtifactStorage.FaultInjector do
  @moduledoc "Deterministic fault boundaries for artifact durability tests."

  @type point :: atom()
  @type result :: :ok | {:error, term()}
  @type t :: nil | (point() -> result()) | %{optional(point()) => result() | (-> result())}

  @doc "Runs one configured fault boundary. Production uses nil."
  @spec run(t(), point()) :: result()
  def run(nil, _point), do: :ok

  def run(injector, point) when is_function(injector, 1), do: normalize(injector.(point))

  def run(injector, point) when is_map(injector) do
    case Map.get(injector, point, :ok) do
      callback when is_function(callback, 0) -> normalize(callback.())
      result -> normalize(result)
    end
  end

  def run(_injector, _point), do: {:error, :invalid_fault_injector}

  @spec normalize(term()) :: result()
  defp normalize(:ok), do: :ok
  defp normalize({:error, _reason} = error), do: error
  defp normalize(other), do: {:error, {:invalid_fault_result, other}}
end
