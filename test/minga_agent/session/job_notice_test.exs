defmodule MingaAgent.Session.JobNoticeTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Session.JobNotice
  alias MingaAgent.Tool.Output.Reference
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @now ~U[2026-11-24 12:00:00Z]

  defp record(id, command) do
    Record.admit(
      id,
      1,
      %{command: command, cwd: "/tmp", background?: true, timeout_secs: 30},
      @now
    )
  end

  defp reference do
    {:ok, token} = Reference.token("session", String.duplicate("a", 32))

    %Reference{
      token: token,
      media_type: "text/plain",
      bytes: 12,
      sha256: String.duplicate("0", 64)
    }
  end

  test "batches every ended job into one host-origin message that is not a user instruction" do
    failed =
      "job-3"
      |> record("make test")
      |> Record.settle(:failed, 42, %{reference: reference(), preview: "PASS"}, @now)

    timed_out = "job-4" |> record("sleep 99") |> Record.settle(:timeout, nil, %{}, @now)
    interrupted = "job-5" |> record("mix phx.server") |> Record.interrupt(:restart, @now)

    assert %Message{
             role: :user,
             content: [%ContentPart{type: :text, text: text}],
             metadata: %{minga_origin: :job_notice, job_ids: ["job-3", "job-4", "job-5"]}
           } = notice = JobNotice.message([failed, timed_out, interrupted])

    assert :ok = JobNotice.validate(notice)
    assert JobNotice.notice?(notice)

    [header, first, second, third] = String.split(text, "\n")
    assert header =~ "Host notice (not from the user)"

    # The process outcome is reported, never the favorable output text.
    assert first =~ "Background job job-3 (`make test`) finished: failed, exit 42."
    refute first =~ "PASS"
    assert first =~ ~s|Output reference for fetch_output: {|
    assert first =~ reference().token

    assert second ==
             ~s|Background job job-4 (`sleep 99`) finished: timeout. Use job_output("job-4") to read its output.|

    assert third =~ "Background job job-5 (`mix phx.server`) was interrupted (restart)."
    assert third =~ "not rerun"

    assert JobNotice.display_text([failed, timed_out, interrupted]) ==
             Enum.join([first, second, third], "\n")
  end

  test "bounds a long command in the rendered line" do
    long = String.duplicate("x", 1_000)
    record = "job-1" |> record(long) |> Record.settle(:completed, 0, %{}, @now)

    assert JobNotice.display_text([record]) =~ "(`" <> String.duplicate("x", 240) <> "...`)"
  end

  test "rejects user content, wrong roles and malformed job ids" do
    valid = JobNotice.message(["job-1" |> record("x") |> Record.settle(:completed, 0, %{}, @now)])

    for invalid <- [
          ReqLLM.Context.user("Background job job-1 finished"),
          %{valid | role: :system},
          %{valid | content: []},
          %{valid | metadata: %{minga_origin: :job_notice, job_ids: []}},
          %{valid | metadata: %{minga_origin: :job_notice, job_ids: [""]}},
          %{valid | metadata: %{minga_origin: :job_notice}},
          :not_a_message
        ] do
      assert {:error, :invalid_job_notice} = JobNotice.validate(invalid)
    end

    refute JobNotice.notice?(ReqLLM.Context.user("hello"))
  end
end
