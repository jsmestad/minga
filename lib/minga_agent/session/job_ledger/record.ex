defmodule MingaAgent.Session.JobLedger.Record do
  @moduledoc """
  One shell job as the owning Session knows it.

  The record holds the job's identity, the JobOwner epoch that ran it, its tagged lifecycle status, a reference to its retained output plus a bounded preview, wall-clock timestamps, and the state of its completion notice. The exit code lives in the terminal status, separate from output text, so a command that prints `PASS` and exits 42 reports failure with exit 42.

  Transitions dispatch on the status tag. Settling or interrupting a record that has already left `:running` returns it unchanged, so exactly one terminal transition takes effect. `MingaAgent.Session.JobLedger` is the only caller.
  """

  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tools.OutputLimit

  @preview_bytes 4_096

  @typedoc "Stable job identifier, unique within a session."
  @type id :: String.t()

  @typedoc "Generation of the JobOwner process that ran the job."
  @type epoch :: pos_integer()

  @typedoc "Outcome of a job that ran to an observed end."
  @type outcome :: :completed | :failed | :timeout | :cancelled | :crashed

  @typedoc "Why a running job lost its supervisor before an observed end."
  @type interrupt_reason :: :owner_down | :restart

  @typedoc "Job lifecycle status."
  @type status ::
          :running
          | {:terminal, outcome(), exit_code :: integer() | nil}
          | {:interrupted, interrupt_reason()}

  @typedoc "Delivery state of the completion notice for the owning agent."
  @type notice :: :none | :pending | :delivered

  @typedoc "Captured output facts reported when a job ends."
  @type output :: %{reference: Reference.t() | nil, preview: String.t() | nil}

  @typedoc "Facts the caller supplies when admitting a job."
  @type spec :: %{
          command: String.t(),
          cwd: String.t(),
          background?: boolean(),
          timeout_secs: pos_integer()
        }

  @type t :: %__MODULE__{
          id: id(),
          epoch: epoch(),
          command: String.t(),
          cwd: String.t(),
          background?: boolean(),
          timeout_secs: pos_integer(),
          status: status(),
          output_ref: Reference.t() | nil,
          preview: String.t() | nil,
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          notice: notice()
        }

  @enforce_keys [:id, :epoch, :command, :cwd, :background?, :timeout_secs, :started_at]
  defstruct [
    :id,
    :epoch,
    :command,
    :cwd,
    :background?,
    :timeout_secs,
    :started_at,
    :output_ref,
    :preview,
    :finished_at,
    status: :running,
    notice: :none
  ]

  @doc "Returns the maximum preview size in bytes."
  @spec preview_bytes() :: pos_integer()
  def preview_bytes, do: @preview_bytes

  @doc "Builds a running record for an admitted job."
  @spec admit(id(), epoch(), spec(), DateTime.t()) :: t()
  def admit(id, epoch, spec, %DateTime{} = now)
      when is_binary(id) and is_integer(epoch) and epoch > 0 do
    %__MODULE__{
      id: id,
      epoch: epoch,
      command: Map.fetch!(spec, :command),
      cwd: Map.fetch!(spec, :cwd),
      background?: Map.fetch!(spec, :background?),
      timeout_secs: Map.fetch!(spec, :timeout_secs),
      started_at: now
    }
  end

  @doc """
  Records the observed end of a running job.

  A background job gets a pending notice; a foreground job's caller already received the result, so it gets none. A record that is no longer running is returned unchanged.
  """
  @spec settle(t(), outcome(), integer() | nil, output(), DateTime.t()) :: t()
  def settle(%__MODULE__{status: :running} = record, outcome, exit_code, output, now)
      when outcome in [:completed, :failed, :timeout, :cancelled, :crashed] and
             (is_nil(exit_code) or is_integer(exit_code)) do
    %{
      record
      | status: {:terminal, outcome, exit_code},
        output_ref: Map.get(output, :reference),
        preview: bounded_preview(Map.get(output, :preview)),
        finished_at: now,
        notice: finished_notice(record)
    }
  end

  def settle(%__MODULE__{status: {:terminal, _outcome, _exit_code}} = record, _, _, _, _),
    do: record

  def settle(%__MODULE__{status: {:interrupted, _reason}} = record, _, _, _, _), do: record

  @doc "Marks a running job whose supervisor is gone. Its outcome is unknown, so it is never reported as running or rerun."
  @spec interrupt(t(), interrupt_reason(), DateTime.t()) :: t()
  def interrupt(%__MODULE__{status: :running} = record, reason, now)
      when reason in [:owner_down, :restart] do
    %{record | status: {:interrupted, reason}, finished_at: now, notice: finished_notice(record)}
  end

  def interrupt(%__MODULE__{status: {:terminal, _outcome, _exit_code}} = record, _reason, _now),
    do: record

  def interrupt(%__MODULE__{status: {:interrupted, _reason}} = record, _reason2, _now), do: record

  @doc "Marks a pending notice delivered. Other notice states are unchanged."
  @spec deliver_notice(t()) :: t()
  def deliver_notice(%__MODULE__{notice: :pending} = record), do: %{record | notice: :delivered}

  def deliver_notice(%__MODULE__{notice: notice} = record) when notice in [:none, :delivered],
    do: record

  @doc "Returns true while the job's process may still be running."
  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{status: :running}), do: true
  def running?(%__MODULE__{}), do: false

  @doc "Returns true when the record may be evicted: it has ended and owes no notice."
  @spec evictable?(t()) :: boolean()
  def evictable?(%__MODULE__{status: :running}), do: false
  def evictable?(%__MODULE__{notice: :pending}), do: false
  def evictable?(%__MODULE__{}), do: true

  @doc "Returns the user-visible status name."
  @spec status_name(t()) :: :running | outcome() | :interrupted
  def status_name(%__MODULE__{status: :running}), do: :running
  def status_name(%__MODULE__{status: {:terminal, outcome, _exit_code}}), do: outcome
  def status_name(%__MODULE__{status: {:interrupted, _reason}}), do: :interrupted

  @doc "Returns the observed exit code, or nil when none was observed."
  @spec exit_code(t()) :: integer() | nil
  def exit_code(%__MODULE__{status: {:terminal, _outcome, exit_code}}), do: exit_code
  def exit_code(%__MODULE__{}), do: nil

  @spec finished_notice(t()) :: notice()
  defp finished_notice(%__MODULE__{background?: true}), do: :pending
  defp finished_notice(%__MODULE__{background?: false}), do: :none

  @spec bounded_preview(String.t() | nil) :: String.t() | nil
  defp bounded_preview(nil), do: nil

  defp bounded_preview(text) when is_binary(text),
    do: OutputLimit.utf8_prefix(text, @preview_bytes)
end
