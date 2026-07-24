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

  test "current-origin response stores identity and is taken once" do
    ref = make_ref()
    client = spawn_process()
    buffer = spawn_process()

    assert {:ok, pending} =
             PendingRequests.track_response(
               PendingRequests.new(),
               ref,
               :definition,
               client,
               buffer,
               7,
               nil,
               {3, 4}
             )

    assert PendingRequests.fetch(pending, ref) ==
             {:ok, {:response, :definition, client, buffer, 7, nil, {3, 4}}}

    assert {:ok, {:response, :definition, ^client, ^buffer, 7, nil, {3, 4}}, pending} =
             PendingRequests.take(pending, ref)

    assert PendingRequests.fetch(pending, ref) == :error
  end

  test "current-origin response accepts nil cursor only for buffer-scoped L06 kinds" do
    client = spawn_process()
    buffer = spawn_process()

    assert {:ok, pending} =
             PendingRequests.track_response(
               PendingRequests.new(),
               make_ref(),
               :document_symbol,
               client,
               buffer,
               7,
               nil,
               nil
             )

    assert {:ok, pending} =
             PendingRequests.track_response(
               pending,
               make_ref(),
               :workspace_symbol,
               client,
               buffer,
               7,
               nil,
               nil
             )

    assert {:ok, pending} =
             PendingRequests.track_response(
               pending,
               make_ref(),
               :incoming_calls,
               client,
               buffer,
               7,
               nil,
               nil
             )

    assert {:ok, _pending} =
             PendingRequests.track_response(
               pending,
               make_ref(),
               :outgoing_calls,
               client,
               buffer,
               7,
               nil,
               nil
             )

    cursor_required_kind = String.to_existing_atom("definition")

    assert_raise FunctionClauseError, fn ->
      PendingRequests.track_response(
        PendingRequests.new(),
        make_ref(),
        cursor_required_kind,
        client,
        buffer,
        7,
        nil,
        nil
      )
    end
  end

  test "L07 response tracking uses typed variants while L08 legacy atoms remain" do
    client = spawn_process()
    buffer = spawn_process()
    raw_item = %{"label" => "a"}

    assert {:ok, pending} =
             PendingRequests.track_completion_result(
               PendingRequests.new(),
               make_ref(),
               :primary,
               client,
               buffer,
               1,
               2,
               {3, 4}
             )

    assert {:ok, pending} =
             PendingRequests.track_completion_resolve(
               pending,
               make_ref(),
               client,
               buffer,
               1,
               2,
               raw_item
             )

    assert {:ok, pending} =
             PendingRequests.track_signature_help(pending, make_ref(), client, buffer, 1, {3, 4})

    assert {:ok, pending} = PendingRequests.track_response(pending, make_ref(), :code_lens)

    assert {:ok, pending} =
             PendingRequests.track_response(pending, make_ref(), :code_lens_resolve)

    assert {:ok, _pending} = PendingRequests.track_response(pending, make_ref(), :inlay_hint)

    completion_resolve = String.to_existing_atom("completion_resolve")
    signature_help = String.to_existing_atom("signature_help")

    assert_raise FunctionClauseError, fn ->
      PendingRequests.track_response(PendingRequests.new(), make_ref(), completion_resolve)
    end

    assert_raise FunctionClauseError, fn ->
      PendingRequests.track_response(PendingRequests.new(), make_ref(), signature_help)
    end
  end

  test "current-origin response rejects invalid version and cursor" do
    client = spawn_process()
    buffer = spawn_process()

    assert_raise FunctionClauseError, fn ->
      PendingRequests.track_response(
        PendingRequests.new(),
        make_ref(),
        :definition,
        client,
        buffer,
        -1,
        nil,
        {0, 0}
      )
    end

    assert_raise FunctionClauseError, fn ->
      PendingRequests.track_response(
        PendingRequests.new(),
        make_ref(),
        :definition,
        client,
        buffer,
        0,
        nil,
        {-1, 0}
      )
    end
  end

  test "rejects duplicate refs across L07 L08 response operation and format requests" do
    ref = make_ref()
    operation = operation(spawn_process(), ref)
    pending = PendingRequests.new()

    assert {:ok, pending} =
             PendingRequests.track_completion_result(
               pending,
               ref,
               :primary,
               self(),
               spawn_process(),
               0,
               1,
               {0, 0}
             )

    assert PendingRequests.track_response(pending, ref, :code_lens) == {:error, :duplicate_ref}

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

    assert {:ok, pending} = PendingRequests.track_response(pending, response_ref, :code_lens)

    assert {:ok, pending} = PendingRequests.track_format(pending, format)

    assert {requests, pending} = PendingRequests.take_operations_for_tab(pending, 10)
    assert requests == [{:operation, :references, 1, 10}]
    assert PendingRequests.fetch(pending, current_ref) == :error
    assert PendingRequests.fetch(pending, other_ref) == {:ok, {:operation, :rename, 2, 20}}
    assert PendingRequests.fetch(pending, response_ref) == {:ok, {:response, :code_lens}}
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
