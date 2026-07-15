defmodule Minga.Extension.InvocationContext do
  @moduledoc """
  Process-local attribution for one dynamically invoked contribution callback.

  Dynamic extension callbacks enter through a framework-owned boundary. That
  boundary installs the authoritative contribution source for the duration of
  the callback so nested APIs can attribute work without inferring ownership
  from module names. The previous context is always restored, including after
  exceptions and nested invocations.

  This narrow API is intentionally suitable for the callback-invoker boundary:
  callers install a source around invocation and consumers only read it.
  """

  alias Minga.Extension.ContributionCleanup

  @context_key {__MODULE__, :source}
  @missing {__MODULE__, :missing}

  @type source :: ContributionCleanup.contribution_source()

  @doc "Runs a callback with an authoritative contribution source installed."
  @spec with_source(source(), (-> result)) :: result when result: var
  def with_source(source, fun) when is_function(fun, 0) do
    previous = Process.get(@context_key, @missing)
    Process.put(@context_key, source)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc "Returns the authoritative source for the current dynamic invocation."
  @spec current_source() :: {:ok, source()} | :none
  def current_source do
    case Process.get(@context_key, @missing) do
      @missing -> :none
      source -> {:ok, source}
    end
  end

  @spec restore(source() | tuple()) :: :ok
  defp restore(@missing) do
    Process.delete(@context_key)
    :ok
  end

  defp restore(source) do
    Process.put(@context_key, source)
    :ok
  end
end
