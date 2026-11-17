defmodule MingaEditor.Agent.PendingApproval do
  @moduledoc """
  A displayed approval bound to the Session process that published it.

  The PID is an ephemeral attachment, not durable session identity. Frontend models receive only the public approval; they never receive this routing handle.
  """

  alias MingaAgent.ToolApproval.Public

  @enforce_keys [:session_pid, :approval]
  defstruct [:session_pid, :approval]

  @type t :: %__MODULE__{
          session_pid: pid(),
          approval: Public.t()
        }

  @doc "Binds a complete approval to its originating Session process."
  @spec new(pid(), Public.t()) :: t()
  def new(session_pid, %Public{} = approval) when is_pid(session_pid) do
    %__MODULE__{session_pid: session_pid, approval: approval}
  end

  @doc "Returns the public approval without its routing attachment."
  @spec public(t() | nil) :: Public.t() | nil
  def public(%__MODULE__{approval: approval}), do: approval
  def public(nil), do: nil
end
