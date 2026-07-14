defmodule MingaEditor.NativeIPC.Server.State do
  @moduledoc "Internal state owned by the native IPC endpoint server."

  alias MingaEditor.NativeIPC.Identity

  @enforce_keys [:listener, :acceptor, :descriptor_path, :identity]
  defstruct [:listener, :acceptor, :descriptor_path, :identity]

  @typedoc "Native IPC endpoint server state."
  @type t :: %__MODULE__{
          listener: port(),
          acceptor: pid(),
          descriptor_path: String.t(),
          identity: Identity.t()
        }

  @doc "Builds server state after the endpoint and acceptor are ready."
  @spec new(port(), pid(), String.t(), Identity.t()) :: t()
  def new(listener, acceptor, descriptor_path, %Identity{} = identity) do
    %__MODULE__{
      listener: listener,
      acceptor: acceptor,
      descriptor_path: descriptor_path,
      identity: identity
    }
  end
end
