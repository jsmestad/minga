defmodule MingaEditor.State.LSP.FormatOperationsTest do
  @moduledoc "Pure lifecycle index invariants for LSP formatting operations."

  use ExUnit.Case, async: true

  alias MingaEditor.State.LSP.FormatOperation
  alias MingaEditor.State.LSP.FormatOperations

  test "tracks unrelated buffers independently and returns the newest operation" do
    first = operation(spawn_process(), make_ref())
    second = operation(spawn_process(), make_ref())

    assert {:ok, operations} = FormatOperations.track(FormatOperations.new(), first)
    assert {:ok, operations} = FormatOperations.track(operations, second)
    assert FormatOperations.fetch(operations, first.ref) == {:ok, first}
    assert FormatOperations.for_buffer(operations, second.buffer) == second
    assert FormatOperations.newest(operations) == second
  end

  test "refuses to replace a Buffer operation without an explicit cancel and drop workflow" do
    buffer = spawn_process()
    first = operation(buffer, make_ref())
    replacement = operation(buffer, make_ref())

    assert {:ok, operations} = FormatOperations.track(FormatOperations.new(), first)
    assert FormatOperations.track(operations, replacement) == {:error, :buffer_busy}

    operations = FormatOperations.drop(operations, first.ref)
    assert {:ok, operations} = FormatOperations.track(operations, replacement)
    assert FormatOperations.for_buffer(operations, buffer) == replacement
  end

  test "dropping the newest operation reveals the previous active operation" do
    first = operation(spawn_process(), make_ref())
    second = operation(spawn_process(), make_ref())
    {:ok, operations} = FormatOperations.track(FormatOperations.new(), first)
    {:ok, operations} = FormatOperations.track(operations, second)

    operations = FormatOperations.drop(operations, second.ref)

    assert FormatOperations.newest(operations) == first
    assert FormatOperations.fetch(operations, second.ref) == :error
  end

  defp operation(buffer, ref) do
    FormatOperation.new(
      client: self(),
      ref: ref,
      buffer: buffer,
      version: 0,
      encoding: :utf8,
      spinner_timer: make_ref(),
      cancellable_timer: make_ref(),
      timeout_timer: make_ref()
    )
  end

  defp spawn_process do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(pid, :stop) end)
    pid
  end
end
