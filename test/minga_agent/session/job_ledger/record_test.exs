defmodule MingaAgent.Session.JobLedger.RecordTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Tool.Output.Reference

  @started ~U[2026-11-24 10:00:00Z]
  @finished ~U[2026-11-24 10:00:05Z]
  @later ~U[2026-11-24 10:00:09Z]
  @no_output %{reference: nil, preview: nil}

  defp record(opts \\ []) do
    spec = %{
      command: "make test",
      cwd: "/project",
      background?: Keyword.get(opts, :background?, false),
      timeout_secs: 30
    }

    Record.admit("job-1", 2, spec, @started)
  end

  defp terminal(opts \\ []),
    do: Record.settle(record(opts), :failed, 42, %{reference: nil, preview: "PASS"}, @finished)

  defp interrupted(opts \\ []), do: Record.interrupt(record(opts), :owner_down, @finished)

  test "admission records a running job with wall-clock start and no notice" do
    assert %Record{
             id: "job-1",
             epoch: 2,
             status: :running,
             started_at: @started,
             finished_at: nil,
             notice: :none
           } = record()
  end

  describe "settle/5" do
    test "a running job takes the observed outcome and exit code separately from its output" do
      settled = terminal()

      assert settled.status == {:terminal, :failed, 42}
      assert settled.preview == "PASS"
      assert settled.finished_at == @finished
      assert Record.exit_code(settled) == 42
      assert Record.status_name(settled) == :failed
    end

    test "every outcome is accepted from running" do
      for outcome <- [:completed, :failed, :timeout, :cancelled, :crashed] do
        assert %Record{status: {:terminal, ^outcome, nil}} =
                 Record.settle(record(), outcome, nil, @no_output, @finished)
      end
    end

    test "notice is pending for background jobs and none for foreground jobs" do
      assert terminal(background?: true).notice == :pending
      assert terminal(background?: false).notice == :none
    end

    test "keeps the output reference and bounds the preview" do
      {:ok, reference} =
        Reference.new(
          token: "artifact:1:#{String.duplicate("a", 64)}:#{String.duplicate("b", 32)}",
          media_type: "text/plain",
          bytes: 10_000,
          sha256: String.duplicate("c", 64)
        )

      long = String.duplicate("é", Record.preview_bytes())

      settled =
        Record.settle(record(), :completed, 0, %{reference: reference, preview: long}, @finished)

      assert settled.output_ref == reference
      assert byte_size(settled.preview) <= Record.preview_bytes()
      assert String.valid?(settled.preview)
    end

    test "an ended record ignores later reports" do
      for ended <- [terminal(), interrupted()] do
        assert Record.settle(ended, :completed, 0, @no_output, @later) == ended
      end
    end
  end

  describe "interrupt/3" do
    test "a running job becomes interrupted with the reason and no exit code" do
      for reason <- [:owner_down, :restart] do
        assert %Record{status: {:interrupted, ^reason}, finished_at: @finished} =
                 rec = Record.interrupt(record(), reason, @finished)

        assert Record.exit_code(rec) == nil
        assert Record.status_name(rec) == :interrupted
      end
    end

    test "notice is pending only for background jobs" do
      assert interrupted(background?: true).notice == :pending
      assert interrupted(background?: false).notice == :none
    end

    test "an ended record is unchanged" do
      for ended <- [terminal(), interrupted()] do
        assert Record.interrupt(ended, :restart, @later) == ended
      end
    end
  end

  test "deliver_notice/1 moves only a pending notice to delivered" do
    assert Record.deliver_notice(terminal(background?: true)).notice == :delivered
    assert Record.deliver_notice(terminal(background?: false)).notice == :none

    delivered = Record.deliver_notice(terminal(background?: true))
    assert Record.deliver_notice(delivered) == delivered
  end

  test "running?/1 and evictable?/1 across every status and notice" do
    cases = [
      {record(), true, false},
      {terminal(background?: false), false, true},
      {terminal(background?: true), false, false},
      {Record.deliver_notice(terminal(background?: true)), false, true},
      {interrupted(background?: false), false, true},
      {interrupted(background?: true), false, false}
    ]

    for {rec, running?, evictable?} <- cases do
      assert Record.running?(rec) == running?, inspect(rec)
      assert Record.evictable?(rec) == evictable?, inspect(rec)
    end
  end
end
