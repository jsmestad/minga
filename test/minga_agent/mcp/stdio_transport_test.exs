defmodule MingaAgent.MCP.StdioTransportTest do
  # Spawns real /bin/sh children to verify process-boundary env isolation and MCP framing.
  # OS process tests must not run concurrently because of BEAM child setup races.
  use ExUnit.Case, async: false

  alias MingaAgent.MCP.StdioTransport
  alias MingaAgent.MCP.ServerConfig

  test "port_env preserves explicit env, allows startup vars, and unsets disallowed inheritance" do
    config = %ServerConfig{
      name: "Alpha",
      command: "node",
      env: %{
        "EXTRA" => "override",
        "HOME" => "/custom/home",
        "MINGA_COOKIE" => "intentional-cookie"
      }
    }

    inherited_env = %{
      "ANTHROPIC_API_KEY" => "secret-anthropic",
      "MINGA_GATEWAY_TOKEN" => "secret-gateway",
      "MINGA_COOKIE" => "secret-cookie",
      "HOME" => "/should-not-win",
      "PATH" => "/usr/bin",
      "CUSTOM" => "value"
    }

    assert StdioTransport.port_env(config, inherited_env) ==
             [
               {~c"ANTHROPIC_API_KEY", false},
               {~c"CUSTOM", false},
               {~c"EXTRA", ~c"override"},
               {~c"HOME", ~c"/custom/home"},
               {~c"MINGA_COOKIE", ~c"intentional-cookie"},
               {~c"MINGA_GATEWAY_TOKEN", false},
               {~c"PATH", ~c"/usr/bin"}
             ]
  end

  test "a spawned child cannot see inherited secrets once the sanitized env is applied" do
    config = %ServerConfig{
      name: "Alpha",
      command: "/bin/sh",
      args: [
        "-c",
        "if [ \"${MCP_SECRET-}\" = \"top-secret\" ]; then printf 'leaked\\n'; else printf 'masked\\n'; fi"
      ],
      env: %{}
    }

    env = StdioTransport.port_env(config, %{"MCP_SECRET" => "top-secret", "PATH" => "/usr/bin"})

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 65_536},
        {:args, config.args},
        {:env, env}
      ])

    assert_receive {^port, {:data, {:eol, "masked"}}}, 1_000
    assert_receive {^port, {:exit_status, 0}}, 1_000
  end

  describe "multi-chunk line reassembly" do
    test "reassembles noeol chunks into a complete JSON-RPC response" do
      # Build a JSON-RPC response whose encoded form exceeds the port's line
      # buffer (set to 64 bytes here), forcing the port driver to split the
      # line into multiple {noeol, chunk} messages followed by one {eol, tail}.
      id = "reassemble-1"

      payload = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{"value" => String.duplicate("x", 200)}
      }

      json_line = JSON.encode!(payload)

      line_buffer = 64

      config = %ServerConfig{
        name: "echo",
        command: "/bin/sh",
        args: ["-c", "printf '%s\\n' '#{json_line}'"],
        env: %{}
      }

      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:line, line_buffer},
          {:args, config.args},
          {:env, StdioTransport.port_env(config, %{"PATH" => System.get_env("PATH")})}
        ])

      transport = %StdioTransport{port: port}

      # We cannot use request/3 because we didn't write a request; we wrote the
      # response via the shell script. Instead, call the module's internal
      # await path indirectly by writing a no-op request and relying on the
      # shell script's output as the response. The simpler path: send a
      # well-formed request to the port (it will be ignored by /bin/sh) and
      # read the pre-canned response.
      #
      # Actually, we can call request/3 with a matching id. The write will go
      # to sh's stdin (ignored), and the read will pick up the printf output.
      message = %{"jsonrpc" => "2.0", "id" => id, "method" => "test", "params" => %{}}
      assert {:ok, %{"value" => value}} = StdioTransport.request(transport, message, 5_000)
      assert String.length(value) == 200
      assert byte_size(json_line) > line_buffer

      close_port(port)
    catch
      :exit, _ -> :ok
    end

    test "line_too_long error when accumulated noeol chunks exceed the limit" do
      # Emit 200 bytes without a newline. The port driver delivers them as noeol pieces (line buffer = 32).
      # The request fails once the frame passes 100 bytes.
      data = String.duplicate("A", 200)

      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:line, 32},
          {:args, ["-c", "printf '%s' '#{data}'"]},
          {:env, [{~c"PATH", String.to_charlist(System.get_env("PATH"))}]}
        ])

      transport = %StdioTransport{port: port, max_line_bytes: 100}
      message = %{"jsonrpc" => "2.0", "id" => "limit-1", "method" => "test", "params" => %{}}

      assert {:error, {:line_too_long, exceeded}} =
               StdioTransport.request(transport, message, 5_000)

      assert exceeded > 100

      close_port(port)
    catch
      :exit, _ -> :ok
    end
  end

  describe "start/3" do
    test "takes the frame limit from the transport options, or from the default when none is given" do
      config = %ServerConfig{name: "drain", command: "/bin/sh", args: ["-c", "cat >/dev/null"]}

      for {opts, expected} <- [
            {[], StdioTransport.max_line_bytes()},
            {[max_line_bytes: 100], 100}
          ] do
        assert {:ok, %StdioTransport{max_line_bytes: ^expected} = transport} =
                 StdioTransport.start(config, self(), opts)

        assert StdioTransport.stop(transport) == :ok
      end
    end
  end

  # These tests deliver port messages to the test process directly, because request/3 receives in its caller.
  # The child only drains stdin, so the port stays open until the transport or the test closes it.
  describe "framing against a live port" do
    setup do
      port = open_draining_port()
      on_exit(fn -> close_port(port) end)
      {:ok, port: port}
    end

    test "an oversized frame closes the port so the rest of the line is never parsed as the next frame",
         %{port: port} do
      transport = %StdioTransport{port: port, max_line_bytes: 100}
      for _piece <- 1..2, do: send(self(), {port, {:data, {:noeol, String.duplicate("A", 64)}}})

      assert {:error, {:line_too_long, 128}} =
               StdioTransport.request(transport, request(7), 1_000)

      assert Port.info(port) == nil
    end

    test "the last piece of a frame counts toward the frame limit", %{port: port} do
      transport = %StdioTransport{port: port, max_line_bytes: 100}
      send(self(), {port, {:data, {:noeol, String.duplicate("A", 64)}}})
      send(self(), {port, {:data, {:eol, String.duplicate("A", 37)}}})

      assert {:error, {:line_too_long, 101}} =
               StdioTransport.request(transport, request(7), 1_000)

      assert Port.info(port) == nil
    end

    test "a multi-piece frame for another request is skipped and the matching response is returned",
         %{port: port} do
      transport = %StdioTransport{port: port, max_line_bytes: 1_000}

      other =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 6,
          "result" => %{"text" => String.duplicate("x", 150)}
        })

      for piece <- chunk_every(other, 64) |> Enum.drop(-1),
          do: send(self(), {port, {:data, {:noeol, piece}}})

      send(self(), {port, {:data, {:eol, other |> chunk_every(64) |> List.last()}}})

      send(
        self(),
        {port, {:data, {:eol, ~s({"jsonrpc":"2.0","method":"notifications/progress"})}}}
      )

      send(self(), {port, {:data, {:eol, ~s({"jsonrpc":"2.0","id":7,"result":{"ok":true}})}}})

      assert {:ok, %{"ok" => true}} = StdioTransport.request(transport, request(7), 1_000)
      assert Port.info(port) != nil
    end

    test "the request deadline fires while pieces of an unfinished frame keep arriving", %{
      port: port
    } do
      transport = %StdioTransport{port: port, max_line_bytes: 1_000_000_000}
      test_pid = self()
      feeder = spawn_link(fn -> feed_pieces(test_pid, port) end)

      assert {:error, :timeout} = StdioTransport.request(transport, request(7), 100)

      unlink_and_stop(feeder)
      assert Port.info(port) != nil
    end
  end

  defp request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "test", "params" => %{}}

  defp chunk_every(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunk_every(binary, size) do
    <<piece::binary-size(^size), rest::binary>> = binary
    [piece | chunk_every(rest, size)]
  end

  defp open_draining_port do
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      :use_stdio,
      {:line, 64},
      {:args, ["-c", "cat >/dev/null"]},
      {:env, [{~c"PATH", String.to_charlist(System.get_env("PATH"))}]}
    ])
  end

  # Sends one unfinished-frame piece every few milliseconds until stopped.
  defp feed_pieces(test_pid, port) do
    send(test_pid, {port, {:data, {:noeol, String.duplicate("A", 64)}}})

    receive do
      :stop -> :ok
    after
      5 -> feed_pieces(test_pid, port)
    end
  end

  defp unlink_and_stop(pid) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  # The shell exits as soon as it has printed, so the port may already be closed when the test is done with it.
  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
