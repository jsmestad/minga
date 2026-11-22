defmodule MingaAgent.ArtifactStore.Capture do
  @moduledoc """
  An opaque handle for one namespace-bound streamed capture.

  The handle carries the bounded wait its store promises for capture calls. A caller that waits longer than `call_timeout` receives `{:error, :storage_timeout}`, and the store cancels the abandoned capture when it next runs.
  """

  @default_call_timeout 30_000

  @type t :: %__MODULE__{id: String.t(), namespace: String.t(), call_timeout: pos_integer()}

  @enforce_keys [:id, :namespace, :call_timeout]
  defstruct [:id, :namespace, :call_timeout]

  @doc false
  @spec new(String.t(), String.t(), pos_integer()) :: t()
  def new(id, namespace, call_timeout)
      when is_binary(id) and is_binary(namespace) and is_integer(call_timeout) and
             call_timeout > 0,
      do: %__MODULE__{id: id, namespace: namespace, call_timeout: call_timeout}

  @doc "Returns the production bound, in milliseconds, for one capture call."
  @spec default_call_timeout() :: pos_integer()
  def default_call_timeout, do: @default_call_timeout
end
