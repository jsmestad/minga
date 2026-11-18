defmodule MingaAgent.ToolCallTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ToolCall
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Range

  test "terminal transitions cover every source tag and preserve stable terminal facts" do
    transitions = [
      {:complete, &ToolCall.complete(&1, "result")},
      {:error, &ToolCall.error(&1, "result")},
      {:denied, &ToolCall.deny(&1, "result")},
      {:cancelled, &ToolCall.cancel(&1, "result")},
      {:error, &ToolCall.expire_approval(&1, "result")},
      {:error, &ToolCall.result_persistence_failed(&1, "result", nil)}
    ]

    for source <- [:running, :complete, :denied, :cancelled, :error],
        {target, transition} <- transitions do
      call =
        ToolCall.restore(
          id: "id",
          name: "shell",
          status: source,
          duration_ms: 12,
          collapsed: false
        )

      next = transition.(call)

      if source == :running do
        assert next.status == target
        assert next.result == "result"
        assert next.is_error == (target != :complete)
      else
        assert next === call
      end

      assert ToolCall.update_partial(next, "late bytes") === next

      assert transition.(ToolCall.set_collapsed(next, false)) ===
               ToolCall.set_collapsed(next, false)
    end
  end

  test "approval resets only a running call's pre-approval elapsed clock" do
    before = System.monotonic_time(:millisecond)
    call = ToolCall.restore(id: "id", name: "shell", started_at: before - 300_000)
    approved = ToolCall.approve_execution(call)
    assert approved.started_at >= before
    assert approved.duration_ms == nil
    assert approved.status == :running

    for status <- [:complete, :denied, :cancelled, :error] do
      terminal = ToolCall.restore(id: "id", name: "shell", status: status, duration_ms: 20)
      assert ToolCall.approve_execution(terminal) === terminal
    end
  end

  test "interruption preserves legacy streamed bytes when typed output is absent" do
    call = ToolCall.new("id", "shell") |> ToolCall.update_partial("captured bytes")
    aborted = ToolCall.abort(call)
    assert aborted.result == "aborted\n\ncaptured bytes"
    assert aborted.status == :error
    assert aborted.terminal_reason == nil
    refute aborted.collapsed
    assert ToolCall.abort(aborted) === aborted
  end

  test "denial and expiry omit execution duration and retain preview and typed output" do
    {:ok, range} = Range.new(:full, :bytes, 0, 6, 6)
    {:ok, output} = Output.new("denied", :complete, range)
    preview = MingaAgent.ToolApproval.Preview.new(:command, "pwd", ["pwd"])
    call = ToolCall.new("id", "shell") |> ToolCall.set_preview(preview)
    denied = ToolCall.deny(call, "denied")
    assert denied.duration_ms == nil
    assert denied.terminal_reason == nil

    expanded = ToolCall.set_collapsed(denied, false)
    enriched = ToolCall.deny(expanded, "denied", output)
    assert enriched.output == output
    assert enriched.preview == preview
    refute enriched.collapsed
    assert enriched.duration_ms == nil
    assert ToolCall.deny(enriched, "different", nil) === enriched
    assert ToolCall.complete(enriched, "success", output) === enriched
    assert ToolCall.deny(enriched, "denied", output) === enriched

    expired = ToolCall.expire_approval(call, "expired", output)
    assert expired.status == :error
    assert expired.terminal_reason == :approval_timeout
    assert expired.duration_ms == nil
    assert expired.output == output
    assert expired.preview == preview
  end

  test "only explicit durable reconciliation can replace conflicting terminal truth" do
    denied =
      ToolCall.new("id", "shell") |> ToolCall.deny("denied") |> ToolCall.set_collapsed(false)

    assert ToolCall.complete(denied, "saved success") == denied
    reconciled = ToolCall.reconcile(denied, :complete, nil, "saved success", nil)
    assert reconciled.status == :complete
    assert reconciled.result == "saved success"
    refute reconciled.is_error
    refute reconciled.collapsed
  end

  test "known non-execution clears even zero elapsed time without changing generic reconciliation" do
    {:ok, selection} = Range.new(:full, :bytes, 0, 8, 8)
    {:ok, output} = Output.new("retained", :complete, selection)
    result = "Not executed.\n\nretained legacy bytes"

    for duration <- [0, 37], collapsed <- [true, false] do
      call =
        ToolCall.restore(
          id: "pending",
          name: "shell",
          status: :error,
          duration_ms: duration,
          result: "retained legacy bytes",
          output: output,
          collapsed: collapsed
        )

      reconciled = ToolCall.reconcile_not_executed(call, result, output)
      assert reconciled.status == :error
      assert reconciled.terminal_reason == nil
      assert reconciled.is_error
      assert reconciled.duration_ms == nil
      assert reconciled.result == result
      assert reconciled.output === output
      assert reconciled.collapsed == collapsed
      assert ToolCall.reconcile_not_executed(reconciled, result, output) === reconciled

      assert ToolCall.reconcile(call, :error, nil, "indeterminate", output).duration_ms ==
               duration

      assert ToolCall.reconcile(call, :complete, nil, "saved result", output).duration_ms ==
               duration
    end
  end

  test "saved outcome parsing never infers denial or success from text or missing facts" do
    for outcome <- [:complete, :denied, :cancelled, :error] do
      assert ToolCall.saved_outcome(%{tool_outcome: outcome, is_error: outcome != :complete}) ==
               {:ok, outcome, nil}
    end

    assert ToolCall.saved_outcome(%{
             tool_outcome: :error,
             tool_outcome_reason: :approval_timeout,
             is_error: true
           }) ==
             {:ok, :error, :approval_timeout}

    assert ToolCall.saved_outcome(%{is_error: false}) == {:error, :invalid_tool_outcome}
    assert ToolCall.saved_outcome(%{is_error: true}) == {:error, :invalid_tool_outcome}

    for metadata <- [
          %{},
          %{tool_outcome: :unknown, is_error: false},
          %{tool_outcome: :denied, is_error: true, tool_outcome_reason: :approval_timeout},
          %{tool_outcome: :complete, is_error: true}
        ] do
      assert ToolCall.saved_outcome(metadata) == {:error, :invalid_tool_outcome}
    end
  end

  describe "new/3" do
    test "creates a running tool call with monotonic timestamp" do
      tc = ToolCall.new("tc1", "bash", %{"command" => "ls"})

      assert tc.id == "tc1"
      assert tc.name == "bash"
      assert tc.args == %{"command" => "ls"}
      assert tc.status == :running
      assert tc.result == ""
      assert tc.output == nil
      assert tc.is_error == false
      assert tc.collapsed == true
      assert tc.auto_approved_scope == nil
      assert is_integer(tc.started_at)
      assert tc.duration_ms == nil
    end

    test "defaults args to empty map" do
      tc = ToolCall.new("tc1", "read")
      assert tc.args == %{}
    end
  end

  describe "complete/2" do
    test "marks tool call as complete with result and duration" do
      tc = ToolCall.new("tc1", "bash")
      completed = ToolCall.complete(tc, "file contents")

      assert completed.status == :complete
      assert completed.result == "file contents"
      assert completed.is_error == false
      assert completed.collapsed == true
      assert is_integer(completed.duration_ms)
      assert completed.duration_ms >= 0
    end

    test "owns the transition from legacy text to typed output facts" do
      {:ok, range} = Range.new(:full, :bytes, 0, 13, 13)
      {:ok, output} = Output.new("file contents", :complete, range)

      completed = ToolCall.new("tc-output", "read_file") |> ToolCall.complete(output.view, output)

      assert completed.result == "file contents"
      assert completed.output == output
    end
  end

  describe "error/2" do
    test "marks tool call as failed with error result" do
      tc = ToolCall.new("tc1", "bash")
      errored = ToolCall.error(tc, "command not found")

      assert errored.status == :error
      assert errored.result == "command not found"
      assert errored.is_error == true
      assert errored.collapsed == true
      assert is_integer(errored.duration_ms)
    end

    test "preserves typed incomplete capture facts on an error" do
      {:ok, range} = Range.new(:captured_prefix, :bytes, 0, 7, :unknown)
      {:ok, output} = Output.new("partial", {:incomplete, :interrupted}, range)

      errored = ToolCall.new("tc-output-error", "shell") |> ToolCall.error(output.view, output)

      assert errored.result == "partial"
      assert errored.output == output
      assert errored.is_error
    end
  end

  describe "abort/1" do
    test "aborts a running tool call" do
      tc = ToolCall.new("tc1", "bash")
      aborted = ToolCall.abort(tc)

      assert aborted.status == :error
      assert aborted.result == "aborted"
      assert aborted.is_error == true
    end

    test "retains typed output and both expansion choices in the owned abort transition" do
      {:ok, selection} = Range.new(:full, :bytes, 0, 8, 8)
      {:ok, output} = Output.new("retained", :complete, selection)

      for collapsed <- [true, false] do
        call =
          ToolCall.restore(
            id: "running",
            name: "shell",
            result: output.view,
            output: output,
            collapsed: collapsed,
            started_at: System.monotonic_time(:millisecond) - 100
          )

        aborted = ToolCall.abort(call)
        assert aborted.status == :error
        assert aborted.terminal_reason == nil
        assert aborted.output === output
        assert aborted.collapsed == collapsed
        assert aborted.result == "aborted\n\nretained"
        assert aborted.is_error
        assert aborted.duration_ms >= 100
        assert ToolCall.abort(aborted) === aborted
      end
    end

    test "is a no-op on already-completed tool calls" do
      tc = ToolCall.new("tc1", "bash") |> ToolCall.complete("done")
      same = ToolCall.abort(tc)

      assert same.status == :complete
      assert same.result == "done"
    end
  end

  describe "update_partial/2" do
    test "sets partial result and expands the display" do
      tc = ToolCall.new("tc1", "bash")
      assert tc.collapsed == true

      updated = ToolCall.update_partial(tc, "partial output")
      assert updated.result == "partial output"
      assert updated.collapsed == false
    end
  end

  describe "toggle_collapsed/1" do
    test "toggles collapsed state" do
      tc = ToolCall.new("tc1", "bash")
      assert tc.collapsed == true

      toggled = ToolCall.toggle_collapsed(tc)
      assert toggled.collapsed == false

      toggled_back = ToolCall.toggle_collapsed(toggled)
      assert toggled_back.collapsed == true
    end
  end

  describe "set_collapsed/2" do
    test "sets collapsed to specific value" do
      tc = ToolCall.new("tc1", "bash")
      expanded = ToolCall.set_collapsed(tc, false)
      assert expanded.collapsed == false
    end
  end

  describe "set_auto_approved_scope/2" do
    test "records the auto-approval scope" do
      tc = ToolCall.new("tc1", "bash")

      trusted = ToolCall.set_auto_approved_scope(tc, :session)
      assert trusted.auto_approved_scope == :session

      cleared = ToolCall.set_auto_approved_scope(trusted, nil)
      assert cleared.auto_approved_scope == nil
    end
  end

  describe "finished?/1" do
    test "returns false for running tool calls" do
      tc = ToolCall.new("tc1", "bash")
      refute ToolCall.finished?(tc)
    end

    test "returns true for completed tool calls" do
      tc = ToolCall.new("tc1", "bash") |> ToolCall.complete("done")
      assert ToolCall.finished?(tc)
    end

    test "returns true for errored tool calls" do
      tc = ToolCall.new("tc1", "bash") |> ToolCall.error("fail")
      assert ToolCall.finished?(tc)
    end
  end

  describe "@enforce_keys" do
    test "requires id and name" do
      assert_raise ArgumentError, fn ->
        struct!(ToolCall, %{name: "bash"})
      end

      assert_raise ArgumentError, fn ->
        struct!(ToolCall, %{id: "tc1"})
      end
    end
  end
end
