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

  test "current-origin response accepts nil cursor for L06 and code lens kinds" do
    client = spawn_process()
    buffer = spawn_process()

    for kind <- [
          :document_symbol,
          :workspace_symbol,
          :incoming_calls,
          :outgoing_calls,
          :code_lens,
          :code_lens_resolve
        ] do
      assert {:ok, pending} =
               PendingRequests.track_response(
                 PendingRequests.new(),
                 make_ref(),
                 kind,
                 client,
                 buffer,
                 7,
                 nil,
                 nil
               )

      assert map_size(pending.by_ref) == 1
    end

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

  test "L07 responses and L08 inlay use typed variants" do
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

    inlay_ref = make_ref()

    assert {:ok, pending} =
             PendingRequests.track_inlay_hint(pending, inlay_ref, client, buffer, 1, nil, 5, 24)

    assert PendingRequests.fetch(pending, inlay_ref) ==
             {:ok, {:inlay_hint, client, buffer, 1, nil, 5, 24}}

    refute function_exported?(PendingRequests, :track_response, 3)
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

    assert_raise FunctionClauseError, fn ->
      PendingRequests.track_inlay_hint(
        PendingRequests.new(),
        make_ref(),
        client,
        buffer,
        0,
        nil,
        -1,
        1
      )
    end

    assert_raise FunctionClauseError, fn ->
      PendingRequests.track_inlay_hint(
        PendingRequests.new(),
        make_ref(),
        client,
        buffer,
        0,
        nil,
        0,
        0
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

    assert PendingRequests.track_inlay_hint(pending, ref, self(), spawn_process(), 0, nil, 0, 1) ==
             {:error, :duplicate_ref}

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

    assert {:ok, pending} =
             PendingRequests.track_response(
               pending,
               response_ref,
               :code_lens,
               spawn_process(),
               spawn_process(),
               0,
               nil,
               nil
             )

    assert {:ok, pending} = PendingRequests.track_format(pending, format)

    {_requests, pending} = PendingRequests.take_operations_for_tab(pending, 10)

    assert PendingRequests.fetch(pending, current_ref) == :error
    assert PendingRequests.fetch(pending, other_ref) == {:ok, {:operation, :rename, 2, 20}}

    assert {:ok, {:response, :code_lens, _client, _buffer, 0, nil, nil}} =
             PendingRequests.fetch(pending, response_ref)

    assert PendingRequests.fetch_format(pending, format.ref) == {:ok, format}
  end

  test "hover mouse and semantic token requests preserve identity exactly" do
    hover_ref = make_ref()
    semantic_ref = make_ref()
    buffer = spawn_process()
    client = spawn_process()
    legend = {["variable"], []}

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

    assert {:ok, pending} =
             PendingRequests.track_semantic_tokens(
               pending,
               semantic_ref,
               client,
               buffer,
               7,
               :utf16,
               legend
             )

    assert PendingRequests.fetch(pending, hover_ref) ==
             {:ok, {:hover_mouse, 12, 34, buffer, 3, 4, 99}}

    assert PendingRequests.fetch(pending, semantic_ref) ==
             {:ok, {:semantic_tokens, client, buffer, 7, :utf16, legend}}

    for {version, legend} <- [{-1, legend}, {7, :bad_legend}] do
      assert_raise FunctionClauseError, fn ->
        PendingRequests.track_semantic_tokens(
          pending,
          make_ref(),
          client,
          buffer,
          version,
          :utf16,
          legend
        )
      end
    end
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
