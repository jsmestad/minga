defmodule MingaEditor.NativeIPC.Identity do
  @moduledoc """
  Authenticated identity for one native IPC endpoint generation.

  The identity crosses from the endpoint server to connection processes and is
  also serialized into the private runtime descriptor consumed by the native
  helper.
  """

  @derive JSON.Encoder
  @enforce_keys [
    :app_instance_id,
    :core_instance_id,
    :app_pid,
    :euid,
    :launch_nonce,
    :socket_path,
    :token
  ]
  defstruct [
    :app_instance_id,
    :core_instance_id,
    :app_pid,
    :euid,
    :launch_nonce,
    :socket_path,
    :token
  ]

  @typedoc "Native IPC endpoint identity."
  @type t :: %__MODULE__{
          app_instance_id: String.t(),
          core_instance_id: String.t(),
          app_pid: pos_integer(),
          euid: non_neg_integer(),
          launch_nonce: String.t() | nil,
          socket_path: String.t(),
          token: String.t()
        }

  @doc "Builds a complete endpoint identity from validated values."
  @spec new(keyword()) :: t()
  def new(attrs) do
    %__MODULE__{
      app_instance_id: Keyword.fetch!(attrs, :app_instance_id),
      core_instance_id: Keyword.fetch!(attrs, :core_instance_id),
      app_pid: Keyword.fetch!(attrs, :app_pid),
      euid: Keyword.fetch!(attrs, :euid),
      launch_nonce: Keyword.fetch!(attrs, :launch_nonce),
      socket_path: Keyword.fetch!(attrs, :socket_path),
      token: Keyword.fetch!(attrs, :token)
    }
  end

  @doc "Returns the JSON descriptor fields, excluding the server-only effective UID."
  @spec descriptor(t(), pos_integer()) :: map()
  def descriptor(%__MODULE__{} = identity, version) when is_integer(version) and version > 0 do
    identity
    |> Map.from_struct()
    |> Map.delete(:euid)
    |> Map.put(:version, version)
  end
end
