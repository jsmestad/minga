defmodule Minga.Extensions.PackLoaderProbe do
  @moduledoc """
  A bundled-pack loader stand-in for supervision tests.

  It reports each start to the process given as `:notify` and returns `:ignore`, the same startup contract the real pack loaders follow.
  """

  @doc "Supervision child spec, built by the shared pack loader lifecycle."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: Minga.Extensions.PackLoader.child_spec(__MODULE__, opts)

  @doc "Reports the load to `:notify` and returns `:ignore`."
  @spec start_link(keyword()) :: :ignore
  def start_link(opts) do
    send(Keyword.fetch!(opts, :notify), {:pack_loaded, self()})
    :ignore
  end
end
