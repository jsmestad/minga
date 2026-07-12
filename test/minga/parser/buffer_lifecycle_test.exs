defmodule Minga.Parser.BufferLifecycleTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.SyncSnapshot
  alias Minga.Parser.BufferConfig
  alias Minga.Parser.BufferLifecycle
  alias Minga.Parser.BufferRegistry
  alias Minga.Parser.ParseScheduler
  alias Minga.Parser.RequestHandler
  alias Minga.Parser.RequestState

  test "eviction fails deferred, fenced, and in-flight requests and ignores late results" do
    buffer = start_supervised!({Minga.Buffer, content: "value", filetype: :elixir})
    config = %BufferConfig{language: "elixir"}
    stale_at = System.monotonic_time(:millisecond) - 1_000
    {_id, :new, buffers} = BufferRegistry.register(BufferRegistry.new(), buffer, config, stale_at)

    deferred_token = make_ref()
    deferred_tag = make_ref()

    deferred = %{
      from: {self(), deferred_tag},
      buffer: buffer,
      command_builder: fn _buffer_id, _request_id -> <<>> end,
      required_sequence: nil
    }

    requests = RequestState.defer(RequestState.new(), deferred_token, deferred)
    in_flight_tag = make_ref()

    {_request_id, requests} =
      RequestState.emit(requests, %{
        from: {self(), in_flight_tag},
        buffer: buffer,
        token: make_ref()
      })

    {[^buffer], {:ok, evicted_buffers, _scheduler, requests}} =
      BufferLifecycle.evict_inactive(
        nil,
        buffers,
        ParseScheduler.new(),
        requests,
        [],
        0
      )

    assert_receive {^deferred_tag, nil}
    assert_receive {^in_flight_tag, nil}
    assert BufferRegistry.fetch(evicted_buffers, buffer) == :error

    late_snapshot = %SyncSnapshot{
      buffer: buffer,
      token: deferred_token,
      sequence: 1,
      changes: :unchanged
    }

    assert RequestHandler.handle_snapshot(requests, evicted_buffers, late_snapshot) == :unhandled
    assert {:noreply, ^requests} = RequestHandler.reply(requests, 1, :late)
    refute_receive {^deferred_tag, _reply}
    refute_receive {^in_flight_tag, _reply}
  end
end
