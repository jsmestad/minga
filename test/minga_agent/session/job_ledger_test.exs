defmodule MingaAgent.Session.JobLedgerTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.JobLedger
  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Tool.Output.Reference

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

  describe "encode/1 and decode/1" do
    test "round-trip every status tag and notice state through JSON" do
      reference = reference()

      {owner_down, ledger} = admit!(JobLedger.new(), background?: true)
      ledger = JobLedger.interrupt_running(ledger, :owner_down, @later)
      {restarted, ledger} = admit!(ledger, background?: true)
      ledger = JobLedger.restore(ledger, @later)

      {running, ledger} = admit!(ledger)
      {completed, ledger} = admit!(ledger)
      {failed, ledger} = admit!(ledger, background?: true)
      {timed_out, ledger} = admit!(ledger)
      {cancelled, ledger} = admit!(ledger, background?: true)
      {crashed, ledger} = admit!(ledger)

      ledger =
        ledger
        |> JobLedger.settle(
          completed.id,
          1,
          :completed,
          0,
          %{reference: reference, preview: "ok"},
          @later
        )
        |> JobLedger.settle(failed.id, 1, :failed, 42, %{reference: nil, preview: "PASS"}, @later)
        |> JobLedger.settle(
          timed_out.id,
          1,
          :timeout,
          nil,
          %{reference: nil, preview: nil},
          @later
        )
        |> JobLedger.settle(cancelled.id, 1, :cancelled, nil, @output, @later)
        |> JobLedger.settle(crashed.id, 1, :crashed, nil, @output, @later)
        |> JobLedger.mark_notices_delivered([cancelled.id])

      assert {:ok, decoded} = round_trip(ledger)
      assert decoded == ledger

      expected = [
        {owner_down.id, {:interrupted, :owner_down}, :pending},
        {restarted.id, {:interrupted, :restart}, :pending},
        {running.id, :running, :none},
        {completed.id, {:terminal, :completed, 0}, :none},
        {failed.id, {:terminal, :failed, 42}, :pending},
        {timed_out.id, {:terminal, :timeout, nil}, :none},
        {cancelled.id, {:terminal, :cancelled, nil}, :delivered},
        {crashed.id, {:terminal, :crashed, nil}, :none}
      ]

      assert Enum.map(JobLedger.list(decoded), &{&1.id, &1.status, &1.notice}) == expected
      assert {:ok, %Record{output_ref: ^reference}} = JobLedger.fetch(decoded, completed.id)
    end

    test "round-trip a running record and keep next_seq" do
      {record, ledger} = admit!(JobLedger.new(), epoch: 3)
      {_ended, ledger} = admit!(ledger)

      assert {:ok, decoded} = round_trip(ledger)
      assert decoded == ledger
      assert {:ok, ^record} = JobLedger.fetch(decoded, record.id)
      assert {:ok, %Record{id: "job-3"}, _ledger} = JobLedger.admit(decoded, spec(), 3, @now)
    end

    test "reject malformed ledgers" do
      {record, ledger} = admit!(JobLedger.new())
      encoded = JobLedger.encode(ledger)
      [entry] = encoded["records"]
      record_map = entry["record"]

      invalid = [
        nil,
        %{encoded | "version" => 2},
        %{encoded | "next_seq" => 1},
        %{encoded | "records" => [entry, entry]},
        %{encoded | "next_seq" => 3, "records" => [entry, %{entry | "seq" => 2}]},
        %{
          encoded
          | "records" => [
              %{entry | "record" => %{record_map | "status" => %{"state" => "paused"}}}
            ]
        },
        %{encoded | "records" => [%{entry | "record" => %{record_map | "notice" => "maybe"}}]},
        %{
          encoded
          | "records" => [%{entry | "record" => %{record_map | "started_at" => "yesterday"}}]
        },
        %{
          encoded
          | "records" => [
              %{entry | "record" => %{record_map | "finished_at" => DateTime.to_iso8601(@later)}}
            ]
        },
        %{
          encoded
          | "records" => [%{entry | "record" => Map.put(record_map, "pid", "#PID<0.1.0>")}]
        },
        %{
          encoded
          | "records" => [%{entry | "record" => %{record_map | "output_ref" => %{"token" => 1}}}]
        }
      ]

      for value <- invalid do
        assert {:error, :invalid_job_ledger} = JobLedger.decode(value), inspect(value)
      end

      assert record.id == record_map["id"]
    end

    test "references lists every retained output reference" do
      reference = reference()
      {first, ledger} = admit!(JobLedger.new())
      {second, ledger} = admit!(ledger)

      ledger =
        ledger
        |> JobLedger.settle(
          first.id,
          1,
          :completed,
          0,
          %{reference: reference, preview: "ok"},
          @later
        )
        |> JobLedger.settle(second.id, 1, :completed, 0, @output, @later)

      assert JobLedger.references(ledger) == [reference]
    end
  end

  describe "restore/2" do
    test "interrupts running records for restart and keeps ended ones unchanged" do
      cases = [
        {[background?: true], :running, {:interrupted, :restart}, :pending},
        {[background?: false], :running, {:interrupted, :restart}, :none},
        {[background?: true], :completed, {:terminal, :completed, 0}, :pending},
        {[background?: false], :completed, {:terminal, :completed, 0}, :none},
        {[background?: true], :owner_down, {:interrupted, :owner_down}, :pending}
      ]

      for {opts, before, status, notice} <- cases do
        {record, ledger} = admit!(JobLedger.new(), opts)
        ledger = put_status(ledger, record, before)

        restored = JobLedger.restore(ledger, @later)

        assert {:ok, %Record{status: ^status, notice: ^notice}} =
                 JobLedger.fetch(restored, record.id),
               inspect({opts, before})

        assert JobLedger.running_count(restored) == 0
        assert restored.next_seq == ledger.next_seq
      end
    end
  end

  describe "empty?/1" do
    test "is true only for a ledger that never admitted a job" do
      assert JobLedger.empty?(JobLedger.new())
      {_record, ledger} = admit!(JobLedger.new())
      refute JobLedger.empty?(ledger)
    end
  end

  defp put_status(ledger, _record, :running), do: ledger
  defp put_status(ledger, record, :completed), do: settle(ledger, record)

  defp put_status(ledger, _record, :owner_down),
    do: JobLedger.interrupt_running(ledger, :owner_down, @later)

  defp round_trip(ledger),
    do: ledger |> JobLedger.encode() |> JSON.encode!() |> JSON.decode!() |> JobLedger.decode()

  defp reference do
    {:ok, token} = Reference.token("job-ledger-test", String.duplicate("a", 32))

    {:ok, reference} =
      Reference.new(
        token: token,
        media_type: "text/plain",
        bytes: 2,
        sha256: Reference.digest("ok")
      )

    reference
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
