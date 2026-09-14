defmodule Minga.Frontend.OperationLedgerTest do
  use ExUnit.Case, async: true

  alias MingaEditor.NativeIPC.Identity
  alias MingaEditor.NativeIPC.OperationLedger
  alias MingaEditor.NativeIPC.OperationNativeResult
  alias MingaEditor.NativeIPC.OperationReceipt
  alias MingaEditor.NativeIPC.OperationReceipt.Evidence
  alias MingaEditor.NativeIPC.OperationReceipt.Target

  @identity Identity.new(
              app_instance_id: "app-instance-operation-ledger",
              core_instance_id: "core-instance-operation-ledger",
              app_pid: 1,
              euid: 501,
              launch_nonce: nil,
              socket_path: "/tmp/operation-ledger.sock",
              token: "token"
            )

  test "tracks admission, exact BEAM application, and exact native readiness separately" do
    path = "/tmp/receipt-target.txt"
    token = Target.token_for_path(path)

    assert {:ok, admitted, ledger} =
             OperationLedger.admit(%OperationLedger{}, @identity, path, token, 10)

    assert admitted.phase == :admitted
    assert admitted.target.path == path
    assert admitted.target.token == token
    assert admitted.target.window_id == 0

    assert {:ok, applied, ledger} =
             OperationLedger.applied(ledger, admitted.operation_id, 7, 12, 20)

    assert applied.phase == :applied
    assert applied.target.window_id == 7
    assert applied.application_revision == 12

    evidence = evidence(token, 12, 7, 2, 41, true)
    last_visible = evidence(Target.token_for_path("/tmp/previous.txt"), 11, 3, 1, 40, true)
    result = native_result(admitted.operation_id, token, :ready, evidence, last_visible)

    assert {:ok, terminal, ledger} = OperationLedger.finish_native(ledger, result, 30)
    assert terminal.phase == :terminal
    assert terminal.outcome == :ready
    assert terminal.evidence == evidence
    assert terminal.last_visible == last_visible

    assert {:ok, ^terminal, ^ledger} = OperationLedger.finish_native(ledger, result, 40)
  end

  test "rejects unrelated, premature, and conflicting late native callbacks without mutation" do
    path = "/tmp/exact-target.txt"
    token = Target.token_for_path(path)

    assert {:ok, receipt, admitted_ledger} =
             OperationLedger.admit(%OperationLedger{}, @identity, path, token, 0)

    premature =
      native_result(receipt.operation_id, token, :ready, evidence(token, 1, 4, 1, 1, true))

    assert {:error, :correlation_mismatch, ^admitted_ledger} =
             OperationLedger.finish_native(admitted_ledger, premature, 1)

    assert {:ok, _applied, ledger} =
             OperationLedger.applied(admitted_ledger, receipt.operation_id, 4, 2, 2)

    wrong_target =
      native_result(
        receipt.operation_id,
        token + 1,
        :ready,
        evidence(token + 1, 2, 4, 1, 2, true)
      )

    assert {:error, :correlation_mismatch, ^ledger} =
             OperationLedger.finish_native(ledger, wrong_target, 3)

    stale_revision =
      native_result(receipt.operation_id, token, :ready, evidence(token, 1, 4, 1, 3, true))

    assert {:error, :correlation_mismatch, ^ledger} =
             OperationLedger.finish_native(ledger, stale_revision, 4)

    missing_boundary =
      native_result(receipt.operation_id, token, :ready, %{
        evidence(token, 2, 4, 1, 3, true)
        | boundary: :none
      })

    assert {:error, :correlation_mismatch, ^ledger} =
             OperationLedger.finish_native(ledger, missing_boundary, 4)

    missing_focus =
      native_result(receipt.operation_id, token, :ready, evidence(token, 2, 4, 1, 3, false))

    assert {:error, :correlation_mismatch, ^ledger} =
             OperationLedger.finish_native(ledger, missing_focus, 4)

    ready = native_result(receipt.operation_id, token, :ready, evidence(token, 2, 4, 1, 3, true))
    assert {:ok, terminal, terminal_ledger} = OperationLedger.finish_native(ledger, ready, 5)

    conflicting_late = %{ready | outcome: :presentation_failed}

    assert {:error, :correlation_mismatch, ^terminal_ledger} =
             OperationLedger.finish_native(terminal_ledger, conflicting_late, 6)

    assert terminal.outcome == :ready
  end

  test "scopes lookup to app and core generations and retains target-aware last-visible evidence" do
    token = Target.token_for_path("/tmp/current.txt")
    prior_token = Target.token_for_path("/tmp/prior.txt")

    assert {:ok, receipt, ledger} =
             OperationLedger.admit(%OperationLedger{}, @identity, "/tmp/current.txt", token, 0)

    assert {:ok, _applied, ledger} =
             OperationLedger.applied(ledger, receipt.operation_id, 8, 3, 1)

    last_visible = evidence(prior_token, 2, 9, 2, 10, true)

    assert {:ok, terminal, ledger} =
             OperationLedger.finish(
               ledger,
               receipt.operation_id,
               :presentation_failed,
               nil,
               last_visible,
               "renderer rejected the frame",
               2
             )

    assert terminal.last_visible.target_token == prior_token
    assert terminal.detail == "renderer rejected the frame"
    assert OperationReceipt.to_map(terminal)["detail"] == "renderer rejected the frame"

    assert {:error, :app_replaced, ^ledger} =
             OperationLedger.lookup(
               ledger,
               @identity,
               "other-app",
               @identity.core_instance_id,
               receipt.operation_id,
               3
             )

    assert {:error, :core_replaced, ^ledger} =
             OperationLedger.lookup(
               ledger,
               @identity,
               @identity.app_instance_id,
               "other-core",
               receipt.operation_id,
               3
             )
  end

  test "idle sweep terminates abandoned operations and expires terminal retention" do
    token = Target.token_for_path("/tmp/abandoned.txt")

    assert {:ok, receipt, ledger} =
             OperationLedger.admit(%OperationLedger{}, @identity, "/tmp/abandoned.txt", token, 0)

    {ledger, []} = OperationLedger.sweep(ledger, OperationLedger.active_retention_ms() - 1)

    {ledger, [expired_active]} =
      OperationLedger.sweep(ledger, OperationLedger.active_retention_ms())

    assert expired_active.operation_id == receipt.operation_id
    assert expired_active.outcome == :indeterminate
    assert OperationLedger.counts(ledger) == %{active: 0, terminal: 1, expired: 0}

    {ledger, []} =
      OperationLedger.sweep(
        ledger,
        OperationLedger.active_retention_ms() + OperationLedger.retention_ms()
      )

    assert OperationLedger.counts(ledger) == %{active: 0, terminal: 0, expired: 1}

    assert {:error, :expired, _ledger} =
             OperationLedger.lookup(
               ledger,
               @identity,
               @identity.app_instance_id,
               @identity.core_instance_id,
               receipt.operation_id,
               100_000
             )
  end

  test "active, terminal, and expired collections stay within shipping bounds" do
    ledger =
      Enum.reduce(1..OperationLedger.max_active(), %OperationLedger{}, fn index, current ->
        path = "/tmp/capacity-#{index}.txt"

        {:ok, _receipt, next} =
          OperationLedger.admit(current, @identity, path, Target.token_for_path(path), index)

        next
      end)

    assert OperationLedger.counts(ledger).active == OperationLedger.max_active()

    assert {:error, :operation_capacity, ledger} =
             OperationLedger.admit(ledger, @identity, "/tmp/overflow.txt", 1, 100)

    {ledger, terminals} =
      OperationLedger.sweep(ledger, 100 + OperationLedger.active_retention_ms())

    assert length(terminals) == OperationLedger.max_active()
    assert OperationLedger.counts(ledger).active == 0

    ledger =
      Enum.reduce(1..(OperationLedger.max_terminal() + 10), ledger, fn index, current ->
        path = "/tmp/terminal-capacity-#{index}.txt"

        {:ok, receipt, current} =
          OperationLedger.admit(
            current,
            @identity,
            path,
            Target.token_for_path(path),
            100_000 + index
          )

        {:ok, _terminal, current} =
          OperationLedger.finish(
            current,
            receipt.operation_id,
            :rejected,
            nil,
            nil,
            100_000 + index
          )

        current
      end)

    counts = OperationLedger.counts(ledger)
    assert counts.terminal == OperationLedger.max_terminal()
    assert counts.expired <= OperationLedger.max_terminal()
  end

  defp evidence(token, application_revision, window_id, generation, frame_seq, focus_ready) do
    %Evidence{
      target_token: token,
      application_revision: application_revision,
      boundary: :metal_drawable_completed,
      generation: generation,
      frame_seq: frame_seq,
      window_id: window_id,
      focus_ready: focus_ready
    }
  end

  defp native_result(operation_id, token, outcome, evidence, last_visible \\ nil) do
    %OperationNativeResult{
      operation_id: operation_id,
      target_token: token,
      outcome: outcome,
      evidence: evidence,
      last_visible: last_visible
    }
  end
end
