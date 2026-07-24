defmodule MingaEditor.State.LSP.PendingRequestsTest do
  @moduledoc "Pure lifecycle index invariants for LSP pending requests."

  use ExUnit.Case, async: true

  alias MingaEditor.State.LSP.FormatOperation
  alias MingaEditor.State.LSP.PendingRequests

  test "tracks unrelated buffers independently and returns the newest format operation" do
    first = operation(spawn_process(), make_ref())
    second = operation(spawn_process(), make_ref())

    assert {:ok, pending} = PendingRequests.track_format(PendingRequests.new(), first)
    assert {:ok, pending} = PendingRequests.track_format(pending, second)
    assert PendingRequests.fetch_format(pending, first.ref) == {:ok, first}
    assert PendingRequests.format_for_buffer(pending, second.buffer) == second
    assert PendingRequests.newest_format(pending) == second
  end

  test "refuses to replace a Buffer format operation without an explicit drop workflow" do
    buffer = spawn_process()
    first = operation(buffer, make_ref())
    replacement = operation(buffer, make_ref())

    assert {:ok, pending} = PendingRequests.track_format(PendingRequests.new(), first)
    assert PendingRequests.track_format(pending, replacement) == {:error, :buffer_busy}

    pending = PendingRequests.drop_format(pending, first.ref)
    assert {:ok, pending} = PendingRequests.track_format(pending, replacement)
    assert PendingRequests.format_for_buffer(pending, buffer) == replacement
  end

  test "take for a format removes it from every index" do
    first = operation(spawn_process(), make_ref())
    second = operation(spawn_process(), make_ref())
    {:ok, pending} = PendingRequests.track_format(PendingRequests.new(), first)
    {:ok, pending} = PendingRequests.track_format(pending, second)

    assert {:ok, {:format, ^second}, pending} = PendingRequests.take(pending, second.ref)
    assert PendingRequests.newest_format(pending) == first
    assert PendingRequests.fetch_format(pending, second.ref) == :error
    assert PendingRequests.format_for_buffer(pending, second.buffer) == nil
  end

  test "rejects duplicate refs across response operation and format requests" do
    ref = make_ref()
    operation = operation(spawn_process(), ref)
    pending = PendingRequests.new()

    assert {:ok, pending} = PendingRequests.track_response(pending, ref, :completion_resolve)

    assert PendingRequests.track_operation(pending, ref, :references, 1, nil) ==
             {:error, :duplicate_ref}

    assert PendingRequests.track_format(pending, operation) == {:error, :duplicate_ref}
  end

  test "take_operations_for_tab retires only matching operations" do
    current_ref = make_ref()
    other_ref = make_ref()
    response_ref = make_ref()
    format = operation(spawn_process(), make_ref())

    assert {:ok, pending} =
             PendingRequests.track_operation(
               PendingRequests.new(),
               current_ref,
               :references,
               1,
               10
             )

    assert {:ok, pending} = PendingRequests.track_operation(pending, other_ref, :rename, 2, 20)
    assert {:ok, pending} = PendingRequests.track_response(pending, response_ref, :hover)
    assert {:ok, pending} = PendingRequests.track_format(pending, format)

    assert {requests, pending} = PendingRequests.take_operations_for_tab(pending, 10)
    assert requests == [{:operation, :references, 1, 10}]
    assert PendingRequests.fetch(pending, current_ref) == :error
    assert PendingRequests.fetch(pending, other_ref) == {:ok, {:operation, :rename, 2, 20}}
    assert PendingRequests.fetch(pending, response_ref) == {:ok, {:response, :hover}}
    assert PendingRequests.fetch_format(pending, format.ref) == {:ok, format}
  end

  test "hover mouse and semantic token requests preserve identity exactly" do
    hover_ref = make_ref()
    semantic_ref = make_ref()
    buffer = spawn_process()

    assert {:ok, pending} =
             PendingRequests.track_hover_mouse(
               PendingRequests.new(),
               hover_ref,
               12,
               34,
               buffer,
               3,
               4,
               99
             )

    assert {:ok, pending} = PendingRequests.track_semantic_tokens(pending, semantic_ref, buffer)

    assert PendingRequests.fetch(pending, hover_ref) ==
             {:ok, {:hover_mouse, 12, 34, buffer, 3, 4, 99}}

    assert PendingRequests.fetch(pending, semantic_ref) == {:ok, {:semantic_tokens, buffer}}
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
