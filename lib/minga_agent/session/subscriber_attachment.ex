defmodule MingaAgent.Session.SubscriberAttachment do
  @moduledoc """
  Canonical identity for one process attached to an agent session.

  The role and monitor reference travel with the PID so subscriber membership cannot exist without its OTP monitor identity.
  """

  @typedoc "Remote attachment role."
  @type role :: :driver | :viewer
  @type question_access :: :none | :local | {:remote, binary()}

  @enforce_keys [:pid, :role, :monitor_ref]
  @derive {Inspect, except: [:question_access]}
  defstruct [:pid, :role, :monitor_ref, question_access: :none]

  @type t :: %__MODULE__{
          pid: pid(),
          role: role(),
          monitor_ref: reference(),
          question_access: question_access()
        }

  @doc "Builds a monitored subscriber attachment."
  @spec new(pid(), role(), reference()) :: t()
  def new(pid, role, monitor_ref)
      when is_pid(pid) and role in [:driver, :viewer] and is_reference(monitor_ref) do
    %__MODULE__{pid: pid, role: role, monitor_ref: monitor_ref}
  end

  @doc "Records that this subscriber can present and resolve structured questions."
  @spec support_questions(t()) :: t()
  def support_questions(%__MODULE__{question_access: :none} = attachment),
    do: %{attachment | question_access: :local}

  def support_questions(%__MODULE__{} = attachment), do: attachment

  @doc "Issues or reuses the private receipt for a remote driver attachment."
  @spec remote_question_access(t(), binary()) :: {binary() | nil, t()}
  def remote_question_access(
        %__MODULE__{role: :driver, question_access: {:remote, receipt}} = attachment,
        _candidate
      ),
      do: {receipt, attachment}

  def remote_question_access(
        %__MODULE__{role: :driver, question_access: :none} = attachment,
        receipt
      )
      when is_binary(receipt),
      do: {receipt, %{attachment | question_access: {:remote, receipt}}}

  def remote_question_access(%__MODULE__{} = attachment, _receipt), do: {nil, attachment}

  @doc "Assigns a new role while preserving subscriber and monitor identity."
  @spec assign_role(t(), role()) :: t()
  def assign_role(%__MODULE__{role: role} = attachment, role), do: attachment

  def assign_role(%__MODULE__{question_access: {:remote, _}} = attachment, :viewer),
    do: %{attachment | role: :viewer, question_access: :none}

  def assign_role(%__MODULE__{} = attachment, role) when role in [:driver, :viewer] do
    %{attachment | role: role}
  end
end
