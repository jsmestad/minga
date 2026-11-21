defmodule Minga.Parser.ParseSyncTest do
  # Opens a real cat Port; keep it serialized with other OS-process tests.
  use ExUnit.Case, async: false

  @moduletag timeout: 10_000

  alias Minga.Buffer.SyncSnapshot
  alias Minga.Parser.BufferConfig
  alias Minga.Parser.BufferRegistration
  alias Minga.Parser.BufferRegistry
  alias Minga.Parser.ParseScheduler
  alias Minga.Parser.ParseSync
  alias Minga.Parser.Protocol
  alias Minga.Parser.RequestHandler
  alias Minga.Parser.RequestState

  test "a completion flushes fenced requests before repumping a dirty registration" do
    port = open_port()
    buffer = self()
    {id, work} = register_buffer(buffer)

    work = ParseSync.pump(work, port, buffer)
    assert_receive {:request_sync_snapshot, :full, ^buffer, token}

    work = ParseSync.handle_snapshot(work, port, full_snapshot(buffer, token))
    work = ParseSync.mark_dirty(work, port, buffer, 2)
    refute_received {:request_sync_snapshot, _, ^buffer, _}

    from = {buffer, make_ref()}
    builder = &Protocol.encode_request_indent(&1, &2, 0)

    assert {:noreply, requests} =
             RequestHandler.enqueue(
               port,
               work.buffers,
               work.requests,
               buffer,
               from,
               10_000,
               builder
             )

    assert_receive {:request_sync_snapshot, 0, ^buffer, request_token}

    work =
      work
      |> ParseSync.put_requests(requests)
      |> ParseSync.handle_snapshot(port, full_snapshot(buffer, request_token))

    parse_timeout = work.scheduler.timeout_token
    assert {:parse, _ref} = parse_timeout
    assert ParseSync.handle_timeout(work, buffer, {:snapshot, token}) == :ok
    assert ParseSync.handle_timeout(work, buffer, parse_timeout) == :restart_port
    assert ParseSync.complete_parse(work, port, buffer, 2) == :stale
    refute_received {:request_sync_snapshot, _, ^buffer, _}

    assert {:ok, work, %BufferRegistration{id: ^id, phase: :idle, last_completed_version: 1}} =
             ParseSync.complete_parse(work, port, buffer, 1)

    assert {%{from: ^from, token: ^request_token}, _requests} =
             RequestState.pop_in_flight(work.requests, 1)

    assert_receive {:request_sync_snapshot, 1, ^buffer, next_token}

    assert {:ok, %BufferRegistration{phase: {:awaiting_snapshot, ^next_token}}} =
             BufferRegistry.fetch(work.buffers, buffer)

    assert ParseSync.handle_timeout(work, buffer, parse_timeout) == :ok
    assert ParseSync.complete_parse(work, port, buffer, 1) == :stale
    ParseSync.reset_admission(work)
    Port.close(port)
  end

  test "a failed write returns the updated registration and admission for restart" do
    port = open_port()
    buffer = self()
    {id, work} = register_buffer(buffer)
    work = ParseSync.pump(work, port, buffer)
    assert_receive {:request_sync_snapshot, :full, ^buffer, token}
    timer = ParseScheduler.timeout_ref(work.scheduler)
    Port.close(port)

    assert ParseSync.handle_snapshot(work, port, full_snapshot(buffer, make_ref())) == work

    assert {:port_write_failed, work} =
             ParseSync.handle_snapshot(work, port, full_snapshot(buffer, token))

    assert {:ok, %BufferRegistration{id: ^id, phase: :idle, force_full?: true}} =
             BufferRegistry.fetch(work.buffers, buffer)

    assert {2, _buffers} = BufferRegistry.next_parse_version(work.buffers)
    assert ParseScheduler.activate_next(work.scheduler) == :empty
    assert Process.read_timer(timer) == false
    assert ParseSync.handle_timeout(work, buffer, {:snapshot, token}) == :ok

    port = open_port()
    work = ParseSync.restart_pumps(work, port)
    assert_receive {:request_sync_snapshot, :full, ^buffer, retry_token}
    refute retry_token == token
    assert BufferRegistry.buffer_id(work.buffers, buffer) == id
    ParseSync.reset_admission(work)
    Port.close(port)
  end

  test "a failed request write replies once and leaves its wire ID available" do
    buffer = self()
    {_id, work} = register_buffer(buffer)
    failed_token = make_ref()
    failed_tag = make_ref()
    requests = fenced_request(work.requests, buffer, failed_token, failed_tag)

    requests = RequestHandler.flush_buffer(nil, requests, work.buffers, buffer)
    assert_receive {^failed_tag, nil}
    requests = RequestHandler.timeout(requests, failed_token)
    refute_received {^failed_tag, _}

    port = open_port()
    tag = make_ref()
    requests = fenced_request(requests, buffer, make_ref(), tag)
    requests = RequestHandler.flush_buffer(port, requests, work.buffers, buffer)

    assert {:noreply, _} = RequestHandler.reply(requests, 1, :answer)
    assert_receive {^tag, :answer}
    Port.close(port)
  end

  defp fenced_request(requests, buffer, token, tag) do
    requests =
      RequestState.defer(requests, token, %{
        from: {buffer, tag},
        buffer: buffer,
        command_builder: &Protocol.encode_request_indent(&1, &2, 0),
        required_sequence: nil
      })

    {:ok, requests} = RequestState.satisfy_fence(requests, token, buffer, 0)
    requests
  end

  defp register_buffer(buffer) do
    work = %ParseSync{}
    config = %BufferConfig{language: "elixir"}
    {id, :new, buffers} = BufferRegistry.register(work.buffers, buffer, config, 0)
    {id, ParseSync.put_buffers(work, buffers)}
  end

  defp full_snapshot(buffer, token) do
    %SyncSnapshot{
      buffer: buffer,
      token: token,
      version: 1,
      sequence: 1,
      changes: {:full, "content"}
    }
  end

  defp open_port do
    # The state transitions only need a writable Port; highlighting is tested against Zig.
    Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, {:packet, 4}])
  end
end
