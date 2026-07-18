defmodule MingaAgent.Session.TurnExecutionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Event
  alias MingaAgent.Session.TurnExecution
  alias MingaAgent.ToolApproval

  @phases [:idle, :starting, :thinking, :approval_waiting, :tool_execution, :completion, :failure]
  @modes [:exec, :plan]

  test "public projections derive from mode and tagged runtime phase" do
    expected_exec_statuses = %{
      idle: :idle,
      starting: :idle,
      thinking: :thinking,
      approval_waiting: :thinking,
      tool_execution: :tool_executing,
      completion: :tool_executing,
      failure: :error
    }

    for phase <- @phases do
      execution = state(:exec, phase)
      assert TurnExecution.phase(execution) == phase
      assert TurnExecution.status(execution) == Map.fetch!(expected_exec_statuses, phase)
      assert TurnExecution.active?(execution) == phase in active_phases()
      assert TurnExecution.error(execution) == if(phase == :failure, do: "boom", else: nil)
      assert TurnExecution.pending_approval(execution) != nil == (phase == :approval_waiting)

      assert TurnExecution.active_tool_name(execution) ==
               if(phase == :tool_execution, do: "shell", else: nil)

      plan = state(:plan, phase)
      assert TurnExecution.mode(plan) == :plan
      assert TurnExecution.status(plan) == :plan
      assert TurnExecution.phase(plan) == phase
    end
  end

  test "begin turn accepts inactive phases and rejects every active phase" do
    for mode <- @modes, phase <- [:idle, :failure] do
      source = state(mode, phase)
      assert {:ok, next, []} = TurnExecution.begin_turn(source)
      assert TurnExecution.phase(next) == :starting
    end

    for mode <- @modes, phase <- active_phases() do
      source = state(mode, phase)
      assert {:error, :turn_active, ^source} = TurnExecution.begin_turn(source)
    end
  end

  test "provider start accepts starting and rejects every other phase" do
    for mode <- @modes, phase <- [:starting] do
      source = state(mode, phase)
      assert {:ok, next, effects} = TurnExecution.provider_started(source)
      assert TurnExecution.phase(next) == :thinking
      assert effects == status_effect(mode, :thinking)
    end

    for mode <- @modes, phase <- @phases -- [:starting] do
      source = state(mode, phase)
      assert {:error, :invalid_phase, ^source} = TurnExecution.provider_started(source)
    end
  end

  test "approval is orthogonal to active activity and rejects idle, failure, or concurrent requests" do
    approval = approval("approval-1")

    for mode <- @modes, phase <- @phases -- [:idle, :approval_waiting, :failure] do
      source = state(mode, phase)
      assert {:ok, waiting, effects} = TurnExecution.request_approval(source, approval)
      assert TurnExecution.phase(waiting) == :approval_waiting
      assert TurnExecution.pending_approval(waiting) == approval

      assert effects == [
               {:notify, :approval, "Approval needed: shell"},
               {:broadcast, {:approval_pending, ToolApproval.public(approval)}}
             ]
    end

    for mode <- @modes, phase <- [:idle, :failure] do
      source = state(mode, phase)

      assert {:ok, ^source, [{:reject_approval, ^approval}]} =
               TurnExecution.request_approval(source, approval)
    end

    for mode <- @modes do
      waiting = state(mode, :approval_waiting)

      assert {:ok, ^waiting, [{:reject_approval, ^approval}]} =
               TurnExecution.request_approval(waiting, approval)
    end
  end

  test "approval resolution rejects stale identity and declares ordered effects" do
    waiting = state(:exec, :approval_waiting)

    assert {:error, :approval_not_found, ^waiting} =
             TurnExecution.resolve_approval(waiting, "stale", :approve)

    assert {:ok, approval, next, effects} =
             TurnExecution.resolve_approval(waiting, "approval-1", :reject)

    assert TurnExecution.phase(next) == :thinking

    assert effects == [
             {:send_approval_response, approval, :reject},
             {:record_approval_resolution, approval, :reject},
             {:append_approval_rejection, approval},
             :notify_messages_changed,
             {:broadcast, {:approval_resolved, :reject}}
           ]

    for mode <- @modes, phase <- @phases -- [:approval_waiting] do
      source = state(mode, phase)

      assert {:error, :no_pending_approval, ^source} =
               TurnExecution.resolve_approval(source, nil, :approve)
    end
  end

  test "approval resolution preserves every active activity" do
    approval = approval("approval-activity")

    for mode <- @modes, phase <- [:starting, :thinking, :tool_execution, :completion] do
      source = state(mode, phase)
      {:ok, waiting, _effects} = TurnExecution.request_approval(source, approval)

      assert {:ok, ^approval, resumed, _effects} =
               TurnExecution.resolve_approval(waiting, approval.tool_call_id, :approve)

      assert TurnExecution.phase(resumed) == phase
      assert TurnExecution.active_tools(resumed) == TurnExecution.active_tools(source)
    end
  end

  test "approval decisions install session and turn trust before leaving approval wait" do
    for {decision, scope} <- [approve_session: :session, approve_turn: :turn] do
      waiting = state(:exec, :approval_waiting)

      assert {:ok, _approval, next, _effects} =
               TurnExecution.resolve_approval(waiting, nil, decision)

      assert TurnExecution.trust_levels(next) == %{"shell:rm -rf /" => scope}
    end
  end

  test "automatic approval handoff is consumed by matching tool start" do
    execution = state(:exec, :thinking)
    approval_event = approval_event("tool-1")

    assert {:ok, approved, effects} =
             TurnExecution.auto_approve(execution, approval_event, :turn)

    assert length(effects) == 2
    assert hd(effects) |> elem(0) == :send_approval_response
    assert Enum.at(effects, 1) == {:mark_tool_auto_approved, approval_event, :turn}

    waiting = state(:exec, :approval_waiting)

    assert {:ok, still_waiting, _effects} =
             TurnExecution.auto_approve(waiting, approval_event("tool-2"), :session)

    assert TurnExecution.phase(still_waiting) == :approval_waiting
    assert TurnExecution.pending_approval(still_waiting).tool_call_id == "approval-1"

    idle = state(:exec, :idle)

    assert {:ok, ^idle, [{:reject_approval, idle_rejected}]} =
             TurnExecution.auto_approve(idle, approval_event("tool-idle"), :session)

    assert idle_rejected.tool_call_id == "tool-idle"

    failed = state(:exec, :failure)

    assert {:ok, ^failed, [{:reject_approval, rejected}]} =
             TurnExecution.auto_approve(failed, approval_event("tool-3"), :session)

    assert rejected.tool_call_id == "tool-3"

    event = tool_start("tool-1", "shell")
    assert {:ok, :turn, running, tool_effects} = TurnExecution.tool_started(approved, event)
    assert TurnExecution.active_tool_name(running) == "shell"
    assert {:append_tool_start, event, :turn} in tool_effects
  end

  test "tool starts support parallel identities and reject duplicate IDs or inactive phases" do
    source = state(:exec, :thinking)
    first = tool_start("tool-1", "read_file")
    second = tool_start("tool-2", "shell")

    assert {:ok, nil, running, effects} = TurnExecution.tool_started(source, first)
    assert hd(effects) == {:status_changed, :tool_executing}
    assert {:ok, nil, parallel, _effects} = TurnExecution.tool_started(running, second)
    assert TurnExecution.active_tools(parallel) == [{"tool-1", "read_file"}, {"tool-2", "shell"}]
    assert TurnExecution.active_tool_name(parallel) == "shell"

    assert {:error, :tool_already_active, ^parallel} =
             TurnExecution.tool_started(parallel, second)

    idle = state(:exec, :idle)
    assert {:error, :invalid_phase, ^idle} = TurnExecution.tool_started(idle, first)

    failed = state(:exec, :failure)
    assert {:error, :invalid_phase, ^failed} = TurnExecution.tool_started(failed, first)
  end

  test "tool completion removes only matching identity and rejects stale duplicates" do
    source = state(:exec, :thinking)

    {:ok, nil, one, _effects} =
      TurnExecution.tool_started(source, tool_start("tool-1", "read_file"))

    {:ok, nil, two, _effects} = TurnExecution.tool_started(one, tool_start("tool-2", "shell"))

    first_end = tool_end("tool-1", "read_file")
    assert {:ok, remaining, effects} = TurnExecution.tool_completed(two, first_end)
    assert TurnExecution.active_tools(remaining) == [{"tool-2", "shell"}]
    assert {:finish_tool, first_end} in effects

    assert {:error, :tool_not_active, ^remaining} =
             TurnExecution.tool_completed(remaining, first_end)

    second_end = tool_end("tool-2", "shell")
    assert {:ok, completed, _effects} = TurnExecution.tool_completed(remaining, second_end)
    assert TurnExecution.phase(completed) == :completion
    assert TurnExecution.active_tools(completed) == []
    assert TurnExecution.status(completed) == :tool_executing
  end

  test "tool completion preserves a concurrent approval wait" do
    source = state(:exec, :thinking)

    {:ok, nil, running, _effects} =
      TurnExecution.tool_started(source, tool_start("tool-1", "read_file"))

    {:ok, waiting, _effects} = TurnExecution.request_approval(running, approval("approval-1"))

    assert {:ok, next, _effects} =
             TurnExecution.tool_completed(waiting, tool_end("tool-1", "read_file"))

    assert TurnExecution.phase(next) == :approval_waiting
    assert TurnExecution.active_tools(next) == []
    assert TurnExecution.pending_approval(next).tool_call_id == "approval-1"
    assert TurnExecution.status(next) == :tool_executing

    assert {:ok, _approval, resumed, _effects} =
             TurnExecution.resolve_approval(next, "approval-1", :approve)

    assert TurnExecution.phase(resumed) == :completion
    assert TurnExecution.status(resumed) == :tool_executing
  end

  test "prompt admission is exhaustive across runtime phases" do
    for mode <- @modes, phase <- active_phases() do
      source = state(mode, phase)

      assert {:queued, :steering, steered, [{:broadcast, {:prompt_queued, "steer", :steering}}]} =
               TurnExecution.admit_prompt(source, :steering, "steer")

      assert {:queued, :follow_up, followed,
              [{:broadcast, {:prompt_queued, "follow", :follow_up}}]} =
               TurnExecution.admit_prompt(steered, :follow_up, "follow")

      assert TurnExecution.queues(followed) == {["steer"], ["follow"]}
    end

    for mode <- @modes, phase <- [:idle, :failure], kind <- [:steering, :follow_up] do
      source = state(mode, phase)
      assert {:send_now, starting, []} = TurnExecution.admit_prompt(source, kind, "now")
      assert TurnExecution.mode(starting) == mode
      assert TurnExecution.phase(starting) == :starting
      assert TurnExecution.queues(starting) == {[], []}
    end
  end

  test "queue dequeue, recall, and clear preserve FIFO and declare transcript effects" do
    source = state(:exec, :thinking)

    {:queued, :steering, first, _effects} =
      TurnExecution.admit_prompt(source, :steering, "one")

    {:queued, :steering, second, _effects} =
      TurnExecution.admit_prompt(first, :steering, "two")

    {:queued, :follow_up, queued, _effects} =
      TurnExecution.admit_prompt(second, :follow_up, "later")

    assert {["one", "two"], dequeued, [{:append_steering_messages, ["one", "two"]}]} =
             TurnExecution.dequeue_steering(queued)

    assert TurnExecution.queues(dequeued) == {[], ["later"]}

    assert {{[], ["later"]}, recalled, [{:broadcast, :queues_recalled}]} =
             TurnExecution.recall_queues(dequeued)

    assert TurnExecution.queues(recalled) == {[], []}
    assert {cleared, [{:broadcast, :queues_recalled}]} = TurnExecution.clear_queues(queued)
    assert TurnExecution.queues(cleared) == {[], []}
  end

  test "plan mode remains independent from every active runtime phase" do
    for phase <- @phases do
      exec = state(:exec, phase)
      {plan, effects} = TurnExecution.enter_plan(exec)
      assert TurnExecution.mode(plan) == :plan
      assert TurnExecution.phase(plan) == approval_resume_phase(phase)
      assert List.last(effects) == {:status_changed, :plan}

      assert {:changed, resumed, [:announce_exec_mode, {:status_changed, status}]} =
               TurnExecution.enter_exec(plan)

      assert TurnExecution.mode(resumed) == :exec
      assert status == TurnExecution.status(resumed)
      assert {:unchanged, ^resumed, []} = TurnExecution.enter_exec(resumed)
    end
  end

  test "abort rejects approval before provider work and clears only turn-scoped resources" do
    waiting = state(:exec, :approval_waiting)
    waiting = TurnExecution.put_trust(waiting, "turn-tool", :turn)
    waiting = TurnExecution.put_trust(waiting, "session-tool", :session)
    approval = TurnExecution.pending_approval(waiting)

    assert {aborted, effects} = TurnExecution.abort(waiting)
    assert TurnExecution.phase(aborted) == :idle
    assert TurnExecution.trust_levels(aborted) == %{"session-tool" => :session}

    assert effects == [
             {:reject_approval, approval},
             :abort_provider,
             :abort_active_tools,
             {:append_system_message, "Aborted", :info},
             :notify_messages_changed,
             {:status_changed, :idle}
           ]
  end

  test "failure rejects approval and aborts active tools before error publication" do
    running = state(:exec, :tool_execution)
    {:ok, waiting, _effects} = TurnExecution.request_approval(running, approval("approval-1"))
    approval = TurnExecution.pending_approval(waiting)

    assert {failed, effects} = TurnExecution.fail(waiting, "boom")
    assert TurnExecution.phase(failed) == :failure
    assert TurnExecution.error(failed) == "boom"
    assert TurnExecution.pending_approval(failed) == nil
    assert TurnExecution.active_tools(failed) == []

    assert effects == [
             {:reject_approval, approval},
             :abort_active_tools,
             {:notify, :error, "boom"},
             {:status_changed, :error},
             {:append_error_once, "boom"},
             :notify_messages_changed,
             {:broadcast, {:error, "boom"}}
           ]
  end

  test "completion effects precede turn cleanup and queued work starts after trust clears" do
    waiting = state(:exec, :approval_waiting)
    waiting = TurnExecution.put_trust(waiting, "read_file", :turn)

    {:queued, :follow_up, queued, _effects} =
      TurnExecution.admit_prompt(waiting, :follow_up, "next")

    approval = TurnExecution.pending_approval(queued)

    assert {:ok, completing, effects} = TurnExecution.begin_completion(queued, nil)

    assert effects == [
             {:reject_approval, approval},
             :notify_completion,
             :collapse_thinking,
             {:apply_usage, nil},
             :dispatch_stop
           ]

    assert {:send_next, ["next"], starting, []} =
             TurnExecution.finish_completion(completing)

    assert TurnExecution.phase(starting) == :starting
    assert TurnExecution.trust_levels(starting) == %{}
    assert TurnExecution.queues(starting) == {[], []}
    assert {:ok, idle, [{:status_changed, :idle}]} = TurnExecution.queued_send_failed(starting)
    assert TurnExecution.phase(idle) == :idle
  end

  test "completion rejects idle and finish rejects every non-completion phase" do
    for mode <- @modes do
      idle = state(mode, :idle)
      assert {:error, :invalid_phase, ^idle} = TurnExecution.begin_completion(idle, nil)
    end

    for mode <- @modes, phase <- @phases -- [:completion] do
      source = state(mode, phase)
      assert {:error, :invalid_phase, ^source} = TurnExecution.finish_completion(source)
    end
  end

  test "failure update and recovery reject non-failure phases" do
    for mode <- @modes do
      failed = state(mode, :failure)
      assert {:ok, updated} = TurnExecution.update_failure(failed, "retrying")
      assert TurnExecution.error(updated) == "retrying"
      assert {:changed, recovered} = TurnExecution.recover(updated)
      assert TurnExecution.phase(recovered) == :idle
    end

    for mode <- @modes, phase <- @phases -- [:failure] do
      source = state(mode, phase)
      assert {:error, :invalid_phase, ^source} = TurnExecution.update_failure(source, "nope")
      assert {:unchanged, ^source} = TurnExecution.recover(source)
    end
  end

  test "reset and restore reject live approval before clearing all resources" do
    waiting = state(:plan, :approval_waiting)
    waiting = TurnExecution.put_trust(waiting, "shell", :session)
    {:ok, waiting} = TurnExecution.set_boundary(waiting, "lib/a.ex", 1, 2)
    approval = TurnExecution.pending_approval(waiting)

    assert {reset, [{:reject_approval, ^approval}, {:status_changed, :idle}]} =
             TurnExecution.reset(waiting)

    assert reset == TurnExecution.new()

    assert {restored, [{:reject_approval, ^approval}, :abort_provider]} =
             TurnExecution.restore(waiting)

    assert restored == TurnExecution.new()
  end

  test "trust and boundaries are owned without exposing mutation" do
    execution = TurnExecution.new()
    execution = TurnExecution.put_trust(execution, "shell", :turn)
    execution = TurnExecution.put_trust(execution, "read_file", :session)
    assert TurnExecution.trust_levels(execution) == %{"shell" => :turn, "read_file" => :session}

    approval_event = %Event.ToolApproval{
      tool_call_id: "tool-1",
      name: "read_file",
      args: %{},
      reply_to: self()
    }

    assert TurnExecution.trusted_scope(execution, approval_event) == :session
    execution = TurnExecution.revoke_trust(execution, "shell")
    assert TurnExecution.trust_levels(execution) == %{"read_file" => :session}
    assert TurnExecution.trust_levels(TurnExecution.revoke_trust(execution, :all)) == %{}

    assert {:ok, bounded} = TurnExecution.set_boundary(execution, "lib/a.ex", 2, 5)
    assert TurnExecution.boundary(bounded, "lib/a.ex") == {2, 5}

    assert TurnExecution.boundary(TurnExecution.clear_boundary(bounded, "lib/a.ex"), "lib/a.ex") ==
             nil

    assert TurnExecution.boundary(TurnExecution.clear_boundaries(bounded), "lib/a.ex") == nil
    assert {:error, _message} = TurnExecution.set_boundary(execution, "lib/a.ex", 5, 2)
  end

  test "detached-session reclaimability derives from canonical activity and queues" do
    assert TurnExecution.reclaimable?(state(:exec, :idle))
    assert TurnExecution.reclaimable?(state(:exec, :failure))

    for phase <- active_phases() do
      refute TurnExecution.reclaimable?(state(:exec, phase))
    end

    {:queued, :steering, queued, _effects} =
      TurnExecution.admit_prompt(state(:exec, :thinking), :steering, "queued")

    {aborted, _effects} = TurnExecution.abort(queued)
    refute TurnExecution.reclaimable?(aborted)
  end

  test "provider failure is exhaustive across every active phase" do
    for mode <- @modes, phase <- active_phases() do
      source = state(mode, phase)
      {failed, effects} = TurnExecution.provider_failed(source, "provider crashed")

      assert TurnExecution.phase(failed) == :failure
      assert TurnExecution.error(failed) == "provider crashed"
      assert TurnExecution.pending_approval(failed) == nil
      assert TurnExecution.active_tools(failed) == []
      assert List.last(effects) == hd(status_effect(mode, :error))

      if phase == :approval_waiting do
        assert match?({:reject_approval, %ToolApproval{}}, hd(effects))
      end
    end
  end

  test "tool failure completes only the matching identity and rejects duplicate delivery" do
    running = state(:exec, :tool_execution)

    failed_event = %Event.ToolEnd{
      tool_call_id: "tool-1",
      name: "shell",
      result: "command failed",
      is_error: true
    }

    assert {:ok, completing, [{:finish_tool, ^failed_event}]} =
             TurnExecution.tool_completed(running, failed_event)

    assert TurnExecution.phase(completing) == :completion

    assert {:error, :tool_not_active, ^completing} =
             TurnExecution.tool_completed(completing, failed_event)
  end

  test "abort during tool execution and interrupted completion clear active resources" do
    running = state(:exec, :tool_execution)
    {aborted, abort_effects} = TurnExecution.abort(running)
    assert TurnExecution.phase(aborted) == :idle
    assert TurnExecution.active_tools(aborted) == []
    assert :abort_provider in abort_effects
    assert :abort_active_tools in abort_effects

    {:ok, completing, _effects} = TurnExecution.begin_completion(running, nil)
    {interrupted, _effects} = TurnExecution.abort(completing)
    assert TurnExecution.phase(interrupted) == :idle
    assert TurnExecution.pending_approval(interrupted) == nil
    assert TurnExecution.active_tools(interrupted) == []
  end

  test "reset after failure closes boundaries, queues, and turn trust" do
    source = state(:exec, :thinking)

    {:queued, :steering, source, _effects} =
      TurnExecution.admit_prompt(source, :steering, "steer")

    {:queued, :follow_up, source, _effects} =
      TurnExecution.admit_prompt(source, :follow_up, "follow")

    {failed, _effects} = TurnExecution.provider_failed(source, "boom")
    failed = TurnExecution.put_trust(failed, "shell", :turn)
    {:ok, failed} = TurnExecution.set_boundary(failed, "lib/a.ex", 1, 2)

    {reset, effects} = TurnExecution.reset(failed)
    assert reset == TurnExecution.new()
    assert effects == [{:status_changed, :idle}]
  end

  defp state(mode, :idle), do: TurnExecution.new(mode)

  defp state(mode, :starting) do
    {:ok, starting, _effects} = mode |> TurnExecution.new() |> TurnExecution.begin_turn()
    starting
  end

  defp state(mode, :thinking) do
    {:ok, thinking, _effects} = mode |> state(:starting) |> TurnExecution.provider_started()
    thinking
  end

  defp state(mode, :approval_waiting) do
    {:ok, waiting, _effects} =
      mode |> state(:thinking) |> TurnExecution.request_approval(approval("approval-1"))

    waiting
  end

  defp state(mode, :tool_execution) do
    {:ok, nil, running, _effects} =
      mode |> state(:thinking) |> TurnExecution.tool_started(tool_start("tool-1", "shell"))

    running
  end

  defp state(mode, :completion) do
    {:ok, completing, _effects} = mode |> state(:thinking) |> TurnExecution.begin_completion(nil)
    completing
  end

  defp state(mode, :failure) do
    {failed, _effects} = mode |> state(:thinking) |> TurnExecution.fail("boom")
    failed
  end

  defp approval(id) do
    ToolApproval.new(
      tool_call_id: id,
      name: "shell",
      args: %{"command" => "rm -rf /"},
      reply_to: self()
    )
  end

  defp approval_event(id) do
    %Event.ToolApproval{
      tool_call_id: id,
      name: "shell",
      args: %{"command" => "pwd"},
      reply_to: self()
    }
  end

  defp tool_start(id, name) do
    %Event.ToolStart{tool_call_id: id, name: name, args: %{}}
  end

  defp tool_end(id, name) do
    %Event.ToolEnd{tool_call_id: id, name: name, result: "ok", is_error: false}
  end

  defp active_phases,
    do: [:starting, :thinking, :approval_waiting, :tool_execution, :completion]

  defp status_effect(:exec, status), do: [{:status_changed, status}]

  defp status_effect(:plan, status) when status in [:idle, :error],
    do: [:reconsider_idle_gc]

  defp status_effect(:plan, _status), do: []

  defp approval_resume_phase(:approval_waiting), do: :thinking
  defp approval_resume_phase(phase), do: phase
end
