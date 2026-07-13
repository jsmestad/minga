defmodule MingaEditor.State.OperationTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationProgress
  alias MingaEditor.State.OperationQueue

  test "constructs a serializable pending operation" do
    operation = Operation.new(7, :external_format, "buffer:7", "Formatting...", true, 9)

    assert %Operation{
             id: 7,
             kind: :external_format,
             resource: "buffer:7",
             status: :pending,
             message: "Formatting...",
             queue: nil,
             progress: nil,
             cancelable?: true,
             order: 9
           } = operation

    assert JSON.encode!(operation) =~ ~s("id":7)
  end

  test "queue, running, and progress transitions preserve valid semantic state" do
    operation = Operation.new(1, :git_commit, "repo:one", "Pending", true, 1)
    queued = Operation.queued(operation, "Queued", OperationQueue.new!(1, 2))
    progressed = Operation.report_progress(queued, OperationProgress.new!(2, 5))
    running = Operation.running(progressed, "Running")

    assert queued.status == :queued
    assert queued.queue == %OperationQueue{position: 1, total: 2}
    assert progressed.progress == %OperationProgress{current: 2, total: 5}
    assert running.status == :running
    assert running.queue == nil
    assert running.progress == progressed.progress
  end

  test "every terminal status clears queue metadata and cancelability" do
    for status <- [:success, :error, :timeout, :canceled, :stale] do
      operation =
        Operation.new(1, :lsp_rename, "file.ex", "Pending", true, 1)
        |> Operation.queued("Queued", OperationQueue.new!(1, 1))
        |> Operation.finish(status, Atom.to_string(status))

      assert operation.status == status
      assert operation.queue == nil
      refute operation.cancelable?
      assert Operation.terminal?(operation)
      refute Operation.active?(operation)
    end
  end

  test "late lifecycle, progress, and terminal updates are no-ops" do
    terminal =
      Operation.new(1, :lsp_references, "file.ex", "Finding", false, 1)
      |> Operation.finish(:success, "Found")

    assert Operation.running(terminal, "Late") == terminal
    assert Operation.queued(terminal, "Late", OperationQueue.new!(1, 1)) == terminal
    assert Operation.report_progress(terminal, OperationProgress.new!(1, 1)) == terminal
    assert Operation.finish(terminal, :error, "Late failure") == terminal
  end
end
