defmodule Minga.Frontend.WaitRequestsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Events
  alias Minga.Frontend.WaitRequestCompletion
  alias Minga.Frontend.WaitRequests

  setup do
    registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: registry})
    server = start_supervised!({WaitRequests, name: nil, events_registry: registry})
    %{registry: registry, server: server}
  end

  test "a matching source-owned save completes successfully", ctx do
    buffer = buffer_process()
    request_id = request_id()
    target = Path.expand("matching.txt")

    assert :ok = WaitRequests.register(buffer, target, request_id, self(), ctx.server)

    Events.broadcast(
      :buffer_saved,
      %Events.BufferEvent{buffer: buffer, path: target},
      ctx.registry
    )

    assert_receive %WaitRequestCompletion{request_id: ^request_id, outcome: :accepted}
    send(buffer, :stop)
  end

  test "a save after retargeting does not complete the original target", ctx do
    buffer = buffer_process()
    request_id = request_id()
    original = Path.expand("original.txt")
    retargeted = Path.expand("retargeted.txt")

    assert :ok = WaitRequests.register(buffer, original, request_id, self(), ctx.server)
    assert :ok = WaitRequests.accept(buffer, retargeted, ctx.server)
    refute_receive %WaitRequestCompletion{request_id: ^request_id}

    assert :ok = WaitRequests.close(buffer, retargeted, ctx.server)

    assert_receive %WaitRequestCompletion{
      request_id: ^request_id,
      outcome: {:cancelled, "requested target was retargeted"}
    }

    send(buffer, :stop)
  end

  test "multiple waiters on one target all complete", ctx do
    buffer = buffer_process()
    target = Path.expand("shared.txt")
    first = request_id()
    second = request_id()

    assert :ok = WaitRequests.register(buffer, target, first, self(), ctx.server)
    assert :ok = WaitRequests.register(buffer, target, second, self(), ctx.server)
    assert :ok = WaitRequests.accept(buffer, target, ctx.server)

    assert_receive %WaitRequestCompletion{request_id: ^first, outcome: :accepted}
    assert_receive %WaitRequestCompletion{request_id: ^second, outcome: :accepted}
    send(buffer, :stop)
  end

  test "discard, cquit, and buffer death complete non-zero", ctx do
    discard_buffer = buffer_process()
    discard_id = request_id()

    assert :ok =
             WaitRequests.register(discard_buffer, "/tmp/discard", discard_id, self(), ctx.server)

    assert :ok = WaitRequests.cancel(discard_buffer, "discarded without saving", ctx.server)

    assert_receive %WaitRequestCompletion{
      request_id: ^discard_id,
      outcome: {:cancelled, "discarded without saving"}
    }

    send(discard_buffer, :stop)

    dead_buffer = buffer_process()
    dead_id = request_id()
    assert :ok = WaitRequests.register(dead_buffer, "/tmp/dead", dead_id, self(), ctx.server)
    send(dead_buffer, :stop)

    assert_receive %WaitRequestCompletion{
      request_id: ^dead_id,
      outcome: {:cancelled, message}
    }

    assert message =~ "buffer exited before wait completion"
  end

  test "shutdown accepts a clean matching real buffer and drains after acknowledgement", ctx do
    target = Path.join(ctx.tmp_dir, "clean.txt")
    File.write!(target, "clean\n")
    buffer = real_buffer!(target, ctx.registry)
    request_id = request_id()

    assert :ok = WaitRequests.register(buffer, target, request_id, self(), ctx.server)
    assert :ok = WaitRequests.accept_all(ctx.server)
    assert_receive %WaitRequestCompletion{request_id: ^request_id, outcome: :accepted}

    drain = Task.async(fn -> WaitRequests.await_acknowledgements(1_000, ctx.server) end)
    assert Task.yield(drain, 0) == nil
    assert :ok = WaitRequests.acknowledge(request_id, ctx.server)
    assert Task.await(drain) == :ok
  end

  test "shutdown cancels a dirty matching real buffer", ctx do
    target = Path.join(ctx.tmp_dir, "dirty.txt")
    File.write!(target, "saved\n")
    buffer = real_buffer!(target, ctx.registry)
    request_id = request_id()
    assert :ok = Minga.Buffer.insert_text(buffer, "unsaved")

    assert :ok = WaitRequests.register(buffer, target, request_id, self(), ctx.server)
    assert :ok = WaitRequests.accept_all(ctx.server)

    assert_receive %WaitRequestCompletion{
      request_id: ^request_id,
      outcome: {:cancelled, "buffer has unsaved changes at editor shutdown"}
    }

    assert :ok = WaitRequests.acknowledge(request_id, ctx.server)
    assert :ok = WaitRequests.await_acknowledgements(100, ctx.server)
  end

  test "shutdown cancels a stale target after a real buffer is retargeted", ctx do
    original = Path.join(ctx.tmp_dir, "original.txt")
    retargeted = Path.join(ctx.tmp_dir, "retargeted.txt")
    File.write!(original, "original\n")
    File.write!(retargeted, "retargeted\n")
    buffer = real_buffer!(original, ctx.registry)
    request_id = request_id()

    assert :ok = WaitRequests.register(buffer, original, request_id, self(), ctx.server)
    assert :ok = Minga.Buffer.retarget_path(buffer, retargeted)
    assert :ok = WaitRequests.accept_all(ctx.server)

    assert_receive %WaitRequestCompletion{
      request_id: ^request_id,
      outcome: {:cancelled, "requested target was retargeted"}
    }

    assert :ok = WaitRequests.acknowledge(request_id, ctx.server)
    assert :ok = WaitRequests.await_acknowledgements(100, ctx.server)
  end

  test "disconnecting a waiter removes only its request", ctx do
    buffer = buffer_process()
    target = Path.expand("disconnect.txt")
    connected_id = request_id()
    disconnected_id = request_id()

    waiter =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = WaitRequests.register(buffer, target, disconnected_id, waiter, ctx.server)
    assert :ok = WaitRequests.register(buffer, target, connected_id, self(), ctx.server)
    send(waiter, :stop)

    assert :ok = WaitRequests.accept(buffer, target, ctx.server)
    assert_receive %WaitRequestCompletion{request_id: ^connected_id, outcome: :accepted}
    send(buffer, :stop)
  end

  defp real_buffer!(path, registry) do
    start_supervised!({Minga.Buffer, file_path: path, events_registry: registry})
  end

  defp buffer_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp request_id, do: "request-#{System.unique_integer([:positive])}"
end
