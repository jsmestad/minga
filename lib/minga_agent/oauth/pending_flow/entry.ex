defmodule MingaAgent.OAuth.PendingFlow.Entry do
  @moduledoc false

  @enforce_keys [:verifier, :state, :port, :owner_session_id, :owner_client_pid]
  defstruct [:verifier, :state, :port, :owner_session_id, :owner_client_pid]

  @type t :: %__MODULE__{
          verifier: String.t(),
          state: String.t(),
          port: pos_integer(),
          owner_session_id: String.t() | nil,
          owner_client_pid: pid() | nil
        }

  @doc "Creates a pending OAuth flow entry."
  @spec new(String.t(), String.t(), pos_integer(), String.t() | nil, pid() | nil) :: t()
  def new(verifier, state, port, owner_session_id, owner_client_pid)
      when is_binary(verifier) and is_binary(state) and is_integer(port) and port > 0 and
             (is_binary(owner_session_id) or is_nil(owner_session_id)) and
             (is_pid(owner_client_pid) or is_nil(owner_client_pid)) do
    %__MODULE__{
      verifier: verifier,
      state: state,
      port: port,
      owner_session_id: owner_session_id,
      owner_client_pid: owner_client_pid
    }
  end
end
