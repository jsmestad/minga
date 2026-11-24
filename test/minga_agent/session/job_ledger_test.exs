defmodule MingaAgent.Session.JobLedgerTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.JobLedger
  alias MingaAgent.Session.JobLedger.Record

  @now ~U[2026-11-24 10:00:00Z]
  @later ~U[2026-11-24 10:01:00Z]
  @output %{reference: nil, preview: "ok"}

  defp spec(opts \\ []) do
    %{
      command: Keyword.get(opts, :command, "make test"),
      cwd: "/project",
      background?: Keyword.get(opts, :background?, false),
      timeout_secs: 30
    }
  end

  defp admit!(ledger, opts \\ []) do
    {:ok, record, ledger} =
      JobLedger.admit(ledger, spec(opts), Keyword.get(opts, :epoch, 1), @now)

    {record, ledger}
  end

  defp settle(ledger, %Record{id: id, epoch: epoch}),
    do: JobLedger.settle(ledger, id, epoch, :completed, 0, @output, @later)

  describe "admit/4" do
    test "allocates sequential ids and records the job running under the epoch" do
      {first, ledger} = admit!(JobLedger.new(), epoch: 4)
      {second, ledger} = admit!(ledger, epoch: 4)

      assert {first.id, second.id} == {"job-1", "job-2"}
      assert %Record{status: :running, epoch: 4, started_at: %DateTime{}} = first
      assert JobLedger.list(ledger) == [first, second]
      assert JobLedger.running_count(ledger) == 2
    end

    test "refuses past the running limit with a typed session limit" do
      ledger =
        Enum.reduce(1..JobLedger.max_running(), JobLedger.new(), fn _i, acc ->
          acc |> admit!() |> elem(1)
        end)

      assert {:error, {:job_limit, :session, 8}} = JobLedger.admit(ledger, spec(), 1, @now)
    end

    test "evicts the oldest ended record that owes no notice when retention is full" do
      {ledger, records} = fill_retained(fn _i -> [background?: false] end)
      [oldest, second | _rest] = records

      assert {:ok, %Record{id: "job-65"}, ledger} = JobLedger.admit(ledger, spec(), 1, @now)
      assert {:error, :job_not_found} = JobLedger.fetch(ledger, oldest.id)
      assert {:ok, _record} = JobLedger.fetch(ledger, second.id)
      assert length(JobLedger.list(ledger)) == JobLedger.max_retained()
    end

    test "never evicts a pending notice; refuses when nothing can be evicted" do
      {ledger, records} = fill_retained(fn _i -> [background?: true] end)

      assert {:error, {:job_limit, :retained, 64}} = JobLedger.admit(ledger, spec(), 1, @now)

      # Delivering one notice frees exactly that record for eviction.
      target = Enum.at(records, 10)
      ledger = JobLedger.mark_notices_delivered(ledger, [target.id])

      assert {:ok, _record, ledger} = JobLedger.admit(ledger, spec(), 1, @now)
      assert {:error, :job_not_found} = JobLedger.fetch(ledger, target.id)
      assert {:ok, _record} = JobLedger.fetch(ledger, hd(records).id)
    end
  end

  describe "settle/7" do
    test "settles a running job reported by its own epoch" do
      {record, ledger} = admit!(JobLedger.new(), epoch: 2)
      ledger = JobLedger.settle(ledger, record.id, 2, :failed, 42, @output, @later)

      assert {:ok, %Record{status: {:terminal, :failed, 42}, finished_at: @later}} =
               JobLedger.fetch(ledger, record.id)

      assert JobLedger.running_count(ledger) == 0
    end

    test "ignores stale-epoch, unknown, and repeated reports" do
      {record, ledger} = admit!(JobLedger.new(), epoch: 2)

      assert JobLedger.settle(ledger, record.id, 1, :completed, 0, @output, @later) == ledger
      assert JobLedger.settle(ledger, "job-99", 2, :completed, 0, @output, @later) == ledger

      settled = settle(ledger, record)
      assert JobLedger.settle(settled, record.id, 2, :crashed, nil, @output, @later) == settled
    end
  end

  describe "interrupt_running/3" do
    test "interrupts only running jobs and queues notices for background ones" do
      {done, ledger} = admit!(JobLedger.new())
      ledger = settle(ledger, done)
      {foreground, ledger} = admit!(ledger)
      {background, ledger} = admit!(ledger, background?: true)

      ledger = JobLedger.interrupt_running(ledger, :owner_down, @later)

      assert {:ok, %Record{status: {:terminal, :completed, 0}}} = JobLedger.fetch(ledger, done.id)

      assert {:ok, %Record{status: {:interrupted, :owner_down}, notice: :none}} =
               JobLedger.fetch(ledger, foreground.id)

      assert {:ok, %Record{status: {:interrupted, :owner_down}, notice: :pending}} =
               JobLedger.fetch(ledger, background.id)

      assert JobLedger.running_count(ledger) == 0
    end
  end

  describe "notices" do
    test "pending notices list in admission order until marked delivered" do
      {first, ledger} = admit!(JobLedger.new(), background?: true)
      {foreground, ledger} = admit!(ledger)
      {second, ledger} = admit!(ledger, background?: true)
      ledger = ledger |> settle(second) |> settle(foreground) |> settle(first)

      assert Enum.map(JobLedger.pending_notices(ledger), & &1.id) == [first.id, second.id]

      ledger = JobLedger.mark_notices_delivered(ledger, [first.id, "job-99"])
      assert Enum.map(JobLedger.pending_notices(ledger), & &1.id) == [second.id]
      assert {:ok, %Record{notice: :delivered}} = JobLedger.fetch(ledger, first.id)
    end

    test "a running background job owes no notice yet" do
      {_record, ledger} = admit!(JobLedger.new(), background?: true)
      assert JobLedger.pending_notices(ledger) == []
    end
  end

  test "fetch/2 rejects unknown and non-string ids" do
    assert {:error, :job_not_found} = JobLedger.fetch(JobLedger.new(), "job-1")
    assert {:error, :job_not_found} = JobLedger.fetch(JobLedger.new(), 1)
  end

  # Fills retention with ended records, settling each so the running limit is not reached.
  defp fill_retained(opts_for) do
    {ledger, records} =
      Enum.reduce(1..JobLedger.max_retained(), {JobLedger.new(), []}, fn i, {acc, records} ->
        {record, acc} = admit!(acc, opts_for.(i))
        {settle(acc, record), [record | records]}
      end)

    {ledger, Enum.reverse(records)}
  end
end
