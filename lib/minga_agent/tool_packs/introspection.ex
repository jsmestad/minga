defmodule MingaAgent.ToolPacks.Introspection do
  @moduledoc "Opt-in model-callable introspection; Runtime and Gateway discovery remain independent."

  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

  @doc "Returns source-owned introspection declarations."
  @spec specs() :: [Spec.t()]
  def specs, do: MingaAgent.Tools.specs_for_source({:bundle, :introspection_tools})

  @doc "Explicitly enables introspection tools in a registry."
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
