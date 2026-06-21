defmodule MingaAgent.Hooks.CommandRunner.HelperBackend do
  @moduledoc """
  Boundary for the external hook helper process used by `MingaAgent.Hooks.CommandRunner`.

  Production uses the Port-backed implementation. Tests can inject an in-memory backend so timeout and shutdown behavior is verified without depending on OS scheduling, Port mailbox pressure, or wall-clock assertions.
  """

  @typedoc "Opaque backend-owned helper handle."
  @type handle :: term()

  @typedoc "Helper output or lifecycle event returned by the backend."
  @type event ::
          {:data, binary(), handle()}
          | {:exit_status, non_neg_integer(), handle()}
          | :timeout

  @callback start(String.t(), [String.t()], String.t(), keyword()) ::
              {:ok, handle()} | {:error, term()}

  @callback next_event(handle(), non_neg_integer()) :: event()

  @callback stop(handle()) :: :ok
end
