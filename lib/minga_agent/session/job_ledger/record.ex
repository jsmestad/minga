defmodule MingaAgent.Session.JobLedger.Record do
  @moduledoc """
  One shell job as the owning Session knows it.

  The record holds the job's identity, the JobOwner epoch that ran it, its tagged lifecycle status, a reference to its retained output plus a bounded preview, wall-clock timestamps, and the state of its completion notice. The exit code lives in the terminal status, separate from output text, so a command that prints `PASS` and exits 42 reports failure with exit 42.

  Transitions dispatch on the status tag. Settling or interrupting a record that has already left `:running` returns it unchanged, so exactly one terminal transition takes effect. `MingaAgent.Session.JobLedger` is the only caller.
  """

  alias MingaAgent.Tool.Output.Codec, as: OutputCodec
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

  @doc """
  Encodes the record as a JSON-safe map for the session snapshot.

  The map holds identity, status, output reference, preview, timestamps and notice state. It never holds a process or monitor, so a decoded record is history, not live authority.
  """
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = record) do
    %{
      "id" => record.id,
      "epoch" => record.epoch,
      "command" => record.command,
      "cwd" => record.cwd,
      "background" => record.background?,
      "timeout_secs" => record.timeout_secs,
      "status" => encode_status(record.status),
      "output_ref" => OutputCodec.encode_reference(record.output_ref),
      "preview" => record.preview,
      "started_at" => DateTime.to_iso8601(record.started_at),
      "finished_at" => encode_datetime(record.finished_at),
      "notice" => Atom.to_string(record.notice)
    }
  end

  @doc "Decodes a record written by `encode/1`. Rejects any field with an unknown tag or wrong type."
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_job_record}
  def decode(
        %{
          "id" => id,
          "epoch" => epoch,
          "command" => command,
          "cwd" => cwd,
          "background" => background?,
          "timeout_secs" => timeout_secs,
          "status" => status,
          "output_ref" => output_ref,
          "preview" => preview,
          "started_at" => started_at,
          "finished_at" => finished_at,
          "notice" => notice
        } = encoded
      )
      when map_size(encoded) == 12 and is_binary(id) and id != "" and is_integer(epoch) and
             epoch > 0 and is_binary(command) and is_binary(cwd) and is_boolean(background?) do
    with :ok <- validate_bounds(timeout_secs, preview),
         {:ok, status} <- decode_status(status),
         {:ok, notice} <- decode_notice(notice),
         {:ok, %DateTime{} = started_at} <- decode_datetime(started_at),
         {:ok, finished_at} <- decode_datetime(finished_at),
         :ok <- validate_finish(status, finished_at, notice),
         {:ok, output_ref} <- decode_reference(output_ref) do
      {:ok,
       %__MODULE__{
         id: id,
         epoch: epoch,
         command: command,
         cwd: cwd,
         background?: background?,
         timeout_secs: timeout_secs,
         status: status,
         output_ref: output_ref,
         preview: preview,
         started_at: started_at,
         finished_at: finished_at,
         notice: notice
       }}
    else
      _invalid -> {:error, :invalid_job_record}
    end
  end

  def decode(_invalid), do: {:error, :invalid_job_record}

  @spec validate_bounds(term(), term()) :: :ok | :error
  defp validate_bounds(timeout_secs, nil) when is_integer(timeout_secs) and timeout_secs > 0,
    do: :ok

  defp validate_bounds(timeout_secs, preview)
       when is_integer(timeout_secs) and timeout_secs > 0 and is_binary(preview) and
              byte_size(preview) <= @preview_bytes,
       do: :ok

  defp validate_bounds(_timeout_secs, _preview), do: :error

  @spec encode_status(status()) :: map()
  defp encode_status(:running), do: %{"state" => "running"}

  defp encode_status({:terminal, outcome, exit_code}),
    do: %{"state" => "terminal", "outcome" => Atom.to_string(outcome), "exit_code" => exit_code}

  defp encode_status({:interrupted, reason}),
    do: %{"state" => "interrupted", "reason" => Atom.to_string(reason)}

  @spec decode_status(term()) :: {:ok, status()} | :error
  defp decode_status(%{"state" => "running"} = encoded) when map_size(encoded) == 1,
    do: {:ok, :running}

  defp decode_status(%{"state" => "terminal", "outcome" => outcome, "exit_code" => exit_code})
       when is_nil(exit_code) or is_integer(exit_code) do
    case decode_outcome(outcome) do
      {:ok, outcome} -> {:ok, {:terminal, outcome, exit_code}}
      :error -> :error
    end
  end

  defp decode_status(%{"state" => "interrupted", "reason" => "owner_down"}),
    do: {:ok, {:interrupted, :owner_down}}

  defp decode_status(%{"state" => "interrupted", "reason" => "restart"}),
    do: {:ok, {:interrupted, :restart}}

  defp decode_status(_invalid), do: :error

  @spec decode_outcome(term()) :: {:ok, outcome()} | :error
  defp decode_outcome("completed"), do: {:ok, :completed}
  defp decode_outcome("failed"), do: {:ok, :failed}
  defp decode_outcome("timeout"), do: {:ok, :timeout}
  defp decode_outcome("cancelled"), do: {:ok, :cancelled}
  defp decode_outcome("crashed"), do: {:ok, :crashed}
  defp decode_outcome(_invalid), do: :error

  @spec decode_notice(term()) :: {:ok, notice()} | :error
  defp decode_notice("none"), do: {:ok, :none}
  defp decode_notice("pending"), do: {:ok, :pending}
  defp decode_notice("delivered"), do: {:ok, :delivered}
  defp decode_notice(_invalid), do: :error

  # A running record has no end time and owes no notice yet; an ended record has an end time.
  @spec validate_finish(status(), DateTime.t() | nil, notice()) :: :ok | :error
  defp validate_finish(:running, nil, :none), do: :ok
  defp validate_finish(:running, _finished_at, _notice), do: :error
  defp validate_finish(_ended, %DateTime{}, _notice), do: :ok
  defp validate_finish(_ended, nil, _notice), do: :error

  @spec encode_datetime(DateTime.t() | nil) :: String.t() | nil
  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  @spec decode_datetime(term()) :: {:ok, DateTime.t() | nil} | :error
  defp decode_datetime(nil), do: {:ok, nil}

  defp decode_datetime(encoded) when is_binary(encoded) do
    case DateTime.from_iso8601(encoded) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp decode_datetime(_invalid), do: :error

  @spec decode_reference(term()) :: {:ok, Reference.t() | nil} | :error
  defp decode_reference(encoded) do
    case OutputCodec.decode_reference(encoded) do
      {:ok, reference} -> {:ok, reference}
      {:error, _reason} -> :error
    end
  end

  @spec finished_notice(t()) :: notice()
  defp finished_notice(%__MODULE__{background?: true}), do: :pending
  defp finished_notice(%__MODULE__{background?: false}), do: :none

  @spec bounded_preview(String.t() | nil) :: String.t() | nil
  defp bounded_preview(nil), do: nil

  defp bounded_preview(text) when is_binary(text),
    do: OutputLimit.utf8_prefix(text, @preview_bytes)
end
