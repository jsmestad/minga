defmodule MingaAgent.Session.SubscriberAttachment do
  @moduledoc """
  Canonical identity for one process attached to an agent session.

  The role and monitor reference travel with the PID so subscriber membership cannot exist without its OTP monitor identity.
  """

  @typedoc "Remote attachment role."
  @type role :: :driver | :viewer

  @enforce_keys [:pid, :role, :monitor_ref]
  defstruct [:pid, :role, :monitor_ref]

  @type t :: %__MODULE__{
          pid: pid(),
          role: role(),
          monitor_ref: reference()
        }

  @doc "Builds a monitored subscriber attachment."
  @spec new(pid(), role(), reference()) :: t()
  def new(pid, role, monitor_ref)
      when is_pid(pid) and role in [:driver, :viewer] and is_reference(monitor_ref) do
    %__MODULE__{pid: pid, role: role, monitor_ref: monitor_ref}
  end

  @doc "Assigns a new role while preserving subscriber and monitor identity."
  @spec assign_role(t(), role()) :: t()
  def assign_role(%__MODULE__{} = attachment, role) when role in [:driver, :viewer] do
    %{attachment | role: role}
  end
end
