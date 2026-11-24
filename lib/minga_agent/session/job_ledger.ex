defmodule MingaAgent.Session.JobLedger do
  @moduledoc """
  The Session's authority for shell job identity and status.

  Session is the only writer. It admits every job here before the JobOwner runs it, applies each terminal report the JobOwner sends, and marks running jobs interrupted when their JobOwner dies. The JobOwner supervises processes only; it never decides a job's identity or recorded status.

  The ledger is bounded. At most 8 jobs run at once, and at most 64 records are retained. Admission evicts the oldest ended record that owes no notice; when no record can be evicted, admission is refused with a typed limit instead of dropping a pending notice.

  Every function is pure. The caller passes the current time, so records carry wall-clock `DateTime` stamps.
  """

  alias MingaAgent.Session.JobLedger.Record

  @max_running 8
  @max_retained 64

  @typedoc "Why the ledger refused an admission."
  @type limit_error ::
          {:job_limit, :session, pos_integer()} | {:job_limit, :retained, pos_integer()}

  @type t :: %__MODULE__{
          records: %{Record.id() => {pos_integer(), Record.t()}},
          next_seq: pos_integer()
        }

  defstruct records: %{}, next_seq: 1

  @doc "Returns an empty ledger."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the per-session limit on running jobs."
  @spec max_running() :: pos_integer()
  def max_running, do: @max_running

  @doc "Returns the per-session limit on retained records."
  @spec max_retained() :: pos_integer()
  def max_retained, do: @max_retained

  @doc """
  Admits a job as running under the given JobOwner epoch and allocates its id.

  Refuses with `{:job_limit, :session, 8}` when the running limit is reached, and with `{:job_limit, :retained, 64}` when every retained record is still running or owes a notice.
  """
  @spec admit(t(), Record.spec(), Record.epoch(), DateTime.t()) ::
          {:ok, Record.t(), t()} | {:error, limit_error()}
  def admit(%__MODULE__{} = ledger, spec, epoch, %DateTime{} = now) do
    with :ok <- check_running_limit(ledger),
         {:ok, ledger} <- make_room(ledger) do
      seq = ledger.next_seq
      record = Record.admit("job-#{seq}", epoch, spec, now)

      {:ok, record,
       %{ledger | records: Map.put(ledger.records, record.id, {seq, record}), next_seq: seq + 1}}
    end
  end

  @doc """
  Applies a JobOwner's terminal report.

  The report is ignored when the job is unknown, was run by a different epoch, or has already ended.
  """
  @spec settle(
          t(),
          Record.id(),
          Record.epoch(),
          Record.outcome(),
          integer() | nil,
          Record.output(),
          DateTime.t()
        ) :: t()
  def settle(%__MODULE__{} = ledger, id, epoch, outcome, exit_code, output, now) do
    case Map.fetch(ledger.records, id) do
      {:ok, {seq, %Record{epoch: ^epoch} = record}} ->
        put(ledger, seq, Record.settle(record, outcome, exit_code, output, now))

      {:ok, {_seq, %Record{}}} ->
        # A report from an earlier JobOwner epoch is stale; its job was already interrupted.
        ledger

      :error ->
        ledger
    end
  end

  @doc "Marks every running job interrupted, for example when its JobOwner died."
  @spec interrupt_running(t(), Record.interrupt_reason(), DateTime.t()) :: t()
  def interrupt_running(%__MODULE__{} = ledger, reason, now) do
    records =
      Map.new(ledger.records, fn {id, {seq, record}} ->
        {id, {seq, Record.interrupt(record, reason, now)}}
      end)

    %{ledger | records: records}
  end

  @doc "Returns ended records whose notice is pending, oldest first."
  @spec pending_notices(t()) :: [Record.t()]
  def pending_notices(%__MODULE__{} = ledger) do
    ledger |> list() |> Enum.filter(&(&1.notice == :pending))
  end

  @doc "Marks the notices of the given records delivered. Unknown ids are ignored."
  @spec mark_notices_delivered(t(), [Record.id()]) :: t()
  def mark_notices_delivered(%__MODULE__{} = ledger, ids) when is_list(ids) do
    Enum.reduce(ids, ledger, fn id, acc ->
      case Map.fetch(acc.records, id) do
        {:ok, {seq, record}} -> put(acc, seq, Record.deliver_notice(record))
        :error -> acc
      end
    end)
  end

  @doc "Fetches one record by id."
  @spec fetch(t(), Record.id()) :: {:ok, Record.t()} | {:error, :job_not_found}
  def fetch(%__MODULE__{} = ledger, id) when is_binary(id) do
    case Map.fetch(ledger.records, id) do
      {:ok, {_seq, record}} -> {:ok, record}
      :error -> {:error, :job_not_found}
    end
  end

  def fetch(%__MODULE__{}, _id), do: {:error, :job_not_found}

  @doc "Returns every retained record, oldest admission first."
  @spec list(t()) :: [Record.t()]
  def list(%__MODULE__{} = ledger) do
    ledger.records
    |> Map.values()
    |> Enum.sort_by(fn {seq, _record} -> seq end)
    |> Enum.map(fn {_seq, record} -> record end)
  end

  @doc "Returns the number of running jobs."
  @spec running_count(t()) :: non_neg_integer()
  def running_count(%__MODULE__{} = ledger) do
    Enum.count(ledger.records, fn {_id, {_seq, record}} -> Record.running?(record) end)
  end

  @spec check_running_limit(t()) :: :ok | {:error, limit_error()}
  defp check_running_limit(ledger) do
    if running_count(ledger) >= @max_running,
      do: {:error, {:job_limit, :session, @max_running}},
      else: :ok
  end

  @spec make_room(t()) :: {:ok, t()} | {:error, limit_error()}
  defp make_room(%__MODULE__{records: records} = ledger) when map_size(records) < @max_retained,
    do: {:ok, ledger}

  defp make_room(%__MODULE__{} = ledger) do
    evictable =
      Enum.filter(ledger.records, fn {_id, {_seq, record}} -> Record.evictable?(record) end)

    case evictable do
      [] ->
        {:error, {:job_limit, :retained, @max_retained}}

      candidates ->
        {oldest_id, _entry} = Enum.min_by(candidates, fn {_id, {seq, _record}} -> seq end)
        {:ok, %{ledger | records: Map.delete(ledger.records, oldest_id)}}
    end
  end

  @spec put(t(), pos_integer(), Record.t()) :: t()
  defp put(ledger, seq, %Record{id: id} = record),
    do: %{ledger | records: Map.put(ledger.records, id, {seq, record})}
end
