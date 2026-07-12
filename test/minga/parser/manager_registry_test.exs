defmodule Minga.Parser.ManagerRegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.SyncSnapshot
  alias Minga.Parser.BufferConfig
  alias Minga.Parser.Manager

  setup do
    name = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
    server = start_supervised!({Manager, name: name, parser_path: "/missing/minga-parser"})
    %{server: server}
  end

  test "registration owns stable parser identity", %{server: server} do
    first = tracked_pid()
    second = tracked_pid()

    first_id = register(server, first)
    assert register(server, first) == first_id
    assert Manager.resolve_buffer(first_id, server) == first

    second_id = register(server, second)
    assert second_id == first_id + 1
    assert Manager.resolve_buffer(second_id, server) == second
  end

  test "changed inert configuration replaces the parser identity", %{server: server} do
    buffer = tracked_pid()
    first_id = register(server, buffer)

    second_id =
      Manager.register_buffer(
        buffer,
        %BufferConfig{language: "elixir", highlight_query: "(identifier) @variable"},
        server: server
      )

    assert second_id > first_id
    assert Manager.resolve_buffer(first_id, server) == nil
    assert Manager.resolve_buffer(second_id, server) == buffer
    assert monitored?(server, buffer)
  end

  test "unregister is idempotent and removes both identity directions", %{server: server} do
    buffer = tracked_pid()
    id = register(server, buffer)

    assert :ok = Manager.unregister_buffer(buffer, server)
    assert :ok = Manager.unregister_buffer(buffer, server)
    assert Manager.buffer_id(buffer, server) == nil
    assert Manager.resolve_buffer(id, server) == nil
    assert :ok = Manager.request_parse(buffer, server)
    assert :sys.get_state(server)
  end

  test "buffer monitors are idempotent, reference-aware, and removed on unregister", %{
    server: server
  } do
    buffer = tracked_pid()
    id = register(server, buffer)
    assert register(server, buffer) == id
    assert monitored?(server, buffer)

    send(server, {:DOWN, make_ref(), :process, buffer, :fake})
    :sys.get_state(server)
    assert Manager.buffer_id(buffer, server) == id

    assert :ok = Manager.unregister_buffer(buffer, server)
    refute monitored?(server, buffer)
  end

  test "unknown parse requests and late snapshots are harmless no-ops", %{server: server} do
    unknown = tracked_pid()
    Manager.request_parse(unknown, server)

    send(
      server,
      {:buffer_sync_snapshot,
       %SyncSnapshot{
         buffer: unknown,
         token: make_ref(),
         sequence: 1,
         changes: {:full, "ignored"}
       }}
    )

    :sys.get_state(server)
    assert Manager.buffer_id(unknown, server) == nil
  end

  test "eviction removes stale registrations and preserves protected buffers", %{server: server} do
    stale = tracked_pid()
    protected = tracked_pid()
    stale_id = register(server, stale)
    protected_id = register(server, protected)

    receive do
    after
      2 -> :ok
    end

    assert Manager.evict_inactive([protected], 0, server) == {:ok, [stale]}
    assert Manager.resolve_buffer(stale_id, server) == nil
    assert Manager.resolve_buffer(protected_id, server) == protected
    refute monitored?(server, stale)
    assert monitored?(server, protected)
  end

  defp register(server, buffer) do
    Manager.register_buffer(buffer, %BufferConfig{language: "elixir"}, server: server)
  end

  defp monitored?(server, buffer) do
    {:monitors, monitors} = Process.info(server, :monitors)
    {:process, buffer} in monitors
  end

  defp tracked_pid do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end
end
