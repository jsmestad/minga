defmodule Minga.Parser.RequestStateTest do
  use ExUnit.Case, async: true

  alias Minga.Parser.RequestHandler
  alias Minga.Parser.RequestState

  test "accepts the first sequence for the matching buffer and never overwrites it" do
    buffer = self()
    other = start_supervised!({Agent, fn -> nil end})
    token = make_ref()
    tag = make_ref()
    requests = defer(buffer, token, tag)

    assert :stale = RequestState.satisfy_fence(requests, token, other, 9)
    assert {:ok, requests} = RequestState.satisfy_fence(requests, token, buffer, 0)
    assert :stale = RequestState.satisfy_fence(requests, token, buffer, 9)
    assert {%{required_sequence: 0}, drained} = RequestState.pop_deferred(requests, token)
    assert :stale = RequestState.satisfy_fence(drained, token, buffer, 9)
  end

  test "timing out a waiting request replies once and rejects its late snapshot" do
    buffer = self()
    token = make_ref()
    tag = make_ref()
    requests = buffer |> defer(token, tag) |> RequestHandler.timeout(token)

    assert_receive {^tag, nil}
    assert :stale = RequestState.satisfy_fence(requests, token, buffer, 1)
    RequestHandler.timeout(requests, token)
    refute_received {^tag, _}
  end

  test "draining ready requests leaves unready fences and other buffers waiting" do
    buffer = self()
    other = start_supervised!({Agent, fn -> nil end})
    ready = make_ref()
    waiting = make_ref()
    elsewhere = make_ref()

    requests =
      RequestState.new()
      |> defer(buffer, ready, make_ref())
      |> defer(buffer, waiting, make_ref())
      |> defer(other, elsewhere, make_ref())

    assert {:ok, requests} = RequestState.satisfy_fence(requests, ready, buffer, 2)
    assert {:ok, requests} = RequestState.satisfy_fence(requests, waiting, buffer, 3)
    assert {:ok, requests} = RequestState.satisfy_fence(requests, elsewhere, other, 1)
    ready_at_two? = &(&1.required_sequence <= 2)

    assert {[{^ready, _}], requests} = RequestState.take_ready(requests, buffer, ready_at_two?)
    assert {[], ^requests} = RequestState.take_ready(requests, buffer, ready_at_two?)
    assert {[{^elsewhere, _}], requests} = RequestState.take_ready(requests, other, ready_at_two?)
    assert {[{^waiting, _}], _} = RequestState.take_ready(requests, buffer, fn _ -> true end)
  end

  defp defer(buffer, token, tag) do
    defer(RequestState.new(), buffer, token, tag)
  end

  defp defer(requests, buffer, token, tag) do
    RequestState.defer(requests, token, %{
      from: {self(), tag},
      buffer: buffer,
      command_builder: fn _buffer_id, _request_id -> <<>> end,
      required_sequence: nil
    })
  end
end
