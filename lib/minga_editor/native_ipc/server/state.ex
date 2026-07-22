defmodule MingaEditor.NativeIPC.Server.State do
  @moduledoc "Internal state owned by the native IPC endpoint server."

  alias MingaEditor.NativeIPC.Endpoint

  @enforce_keys [:endpoint, :acceptor]
  defstruct [:endpoint, :acceptor]

  @typedoc "Native IPC endpoint server state."
  @type t :: %__MODULE__{
          endpoint: Endpoint.t(),
          acceptor: pid()
        }

  @doc "Builds server state after the endpoint and acceptor are ready."
  @spec new(Endpoint.t(), pid()) :: t()
  def new(%Endpoint{} = endpoint, acceptor) when is_pid(acceptor) do
    %__MODULE__{endpoint: endpoint, acceptor: acceptor}
  end
end
