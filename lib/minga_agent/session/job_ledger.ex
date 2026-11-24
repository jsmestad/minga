defmodule MingaAgent.Session.JobLedger do
  @moduledoc """
  The Session's authority for shell job identity and status.

  Session is the only writer. It admits every job here before the JobOwner runs it, applies each terminal report the JobOwner sends, and marks running jobs interrupted when their JobOwner dies. The JobOwner supervises processes only; it never decides a job's identity or recorded status.

  The ledger is bounded. At most 8 jobs run at once, and at most 64 records are retained. Admission evicts the oldest ended record that owes no notice; when no record can be evicted, admission is refused with a typed limit instead of dropping a pending notice.

  The ledger is saved with the conversation snapshot through `encode/1` and `decode/1`. A saved ledger never holds a process, so a loaded ledger goes through `restore/2`, which marks former live work interrupted instead of claiming it still runs.

  Every function is pure. The caller passes the current time, so records carry wall-clock `DateTime` stamps.
  """

  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Tool.Output.Reference

  @max_running 8
  @max_retained 64
  @encoding_version 1

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

  @doc "Returns true for a ledger that never admitted a job."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{records: records, next_seq: 1}) when map_size(records) == 0, do: true
  def empty?(%__MODULE__{}), do: false

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

  @doc """
  Restores a ledger read from a saved snapshot.

  No JobOwner survives a restart, so every record still running when the snapshot was written becomes `{:interrupted, :restart}`. The job is never reported as running and never rerun. A background job gets a pending notice. `next_seq` is kept, so an old handle never resolves to a new job.
  """
  @spec restore(t(), DateTime.t()) :: t()
  def restore(%__MODULE__{} = ledger, %DateTime{} = now),
    do: interrupt_running(ledger, :restart, now)

  @doc "Returns the retained output reference of every record, for snapshot pinning."
  @spec references(t()) :: [Reference.t()]
  def references(%__MODULE__{} = ledger) do
    for {_id, {_seq, %Record{output_ref: %Reference{} = reference}}} <- ledger.records,
        do: reference
  end

  @doc "Encodes the ledger as a JSON-safe map. Records keep their admission order."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = ledger) do
    records =
      ledger.records
      |> Map.values()
      |> Enum.sort_by(fn {seq, _record} -> seq end)
      |> Enum.map(fn {seq, record} -> %{"seq" => seq, "record" => Record.encode(record)} end)

    %{"version" => @encoding_version, "next_seq" => ledger.next_seq, "records" => records}
  end

  @doc """
  Decodes a ledger written by `encode/1`.

  Rejects the whole ledger when any record is invalid, when sequence numbers or ids repeat, when a sequence number is not below `next_seq`, or when more than the retained limit is present. The decoded ledger is exactly what was saved; call `restore/2` before installing it in a live Session.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_job_ledger}
  def decode(%{"version" => @encoding_version, "next_seq" => next_seq, "records" => records})
      when is_integer(next_seq) and next_seq > 0 and is_list(records) do
    with :ok <- check_retained_count(records),
         {:ok, entries} <- decode_entries(records, next_seq, []),
         :ok <- unique_entries(entries) do
      {:ok,
       %__MODULE__{
         records: Map.new(entries, fn {seq, record} -> {record.id, {seq, record}} end),
         next_seq: next_seq
       }}
    end
  end

  def decode(_invalid), do: {:error, :invalid_job_ledger}

  @spec check_retained_count([term()]) :: :ok | {:error, :invalid_job_ledger}
  defp check_retained_count(records) do
    if length(records) <= @max_retained, do: :ok, else: {:error, :invalid_job_ledger}
  end

  @spec decode_entries([term()], pos_integer(), [{pos_integer(), Record.t()}]) ::
          {:ok, [{pos_integer(), Record.t()}]} | {:error, :invalid_job_ledger}
  defp decode_entries([], _next_seq, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_entries([%{"seq" => seq, "record" => encoded} | rest], next_seq, acc)
       when is_integer(seq) and seq > 0 and seq < next_seq do
    case Record.decode(encoded) do
      {:ok, record} -> decode_entries(rest, next_seq, [{seq, record} | acc])
      {:error, :invalid_job_record} -> {:error, :invalid_job_ledger}
    end
  end

  defp decode_entries(_invalid, _next_seq, _acc), do: {:error, :invalid_job_ledger}

  @spec unique_entries([{pos_integer(), Record.t()}]) :: :ok | {:error, :invalid_job_ledger}
  defp unique_entries(entries) do
    seqs = Enum.map(entries, fn {seq, _record} -> seq end)
    ids = Enum.map(entries, fn {_seq, record} -> record.id end)

    if Enum.uniq(seqs) == seqs and Enum.uniq(ids) == ids,
      do: :ok,
      else: {:error, :invalid_job_ledger}
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
