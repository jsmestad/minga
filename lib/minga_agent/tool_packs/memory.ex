defmodule MingaAgent.ToolPacks.Memory do
  @moduledoc "Opt-in read access to existing user memory, without automatic prompt injection."

  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

  @doc "Returns source-owned memory declarations."
  @spec specs() :: [Spec.t()]
  def specs, do: MingaAgent.Tools.specs_for_source({:bundle, :memory_tools})

  @doc "Explicitly enables memory read tools in a registry."
  @spec register(atom()) :: :ok | {:error, term()}
  def register(table \\ Registry) do
    Enum.reduce_while(specs(), :ok, fn spec, :ok ->
      case Registry.register(table, spec) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
