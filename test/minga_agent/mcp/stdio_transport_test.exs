defmodule MingaAgent.MCP.StdioTransportTest do
  # Spawns a real /bin/sh child to verify process-boundary env isolation
  # and MCP line accumulation. OS process tests must not run concurrently
  # because of BEAM child setup races. The size-limit test also mutates
  # Application env (:minga, :mcp_max_line_bytes).
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

      Port.close(port)
    catch
      :exit, _ -> :ok
    end

    test "line_too_long error when accumulated noeol chunks exceed the limit" do
      # Set a tiny limit so we can trigger it without generating megabytes.
      prev = Application.get_env(:minga, :mcp_max_line_bytes)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:minga, :mcp_max_line_bytes, prev),
          else: Application.delete_env(:minga, :mcp_max_line_bytes)
      end)

      Application.put_env(:minga, :mcp_max_line_bytes, 100)

      # Emit 200 bytes without a newline, then exit. The port driver will
      # deliver these as noeol chunks (line buffer = 32), and the accumulator
      # should bail once total bytes > 100.
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

      transport = %StdioTransport{port: port}
      message = %{"jsonrpc" => "2.0", "id" => "limit-1", "method" => "test", "params" => %{}}

      assert {:error, {:line_too_long, exceeded}} =
               StdioTransport.request(transport, message, 5_000)

      assert exceeded > 100

      Port.close(port)
    catch
      :exit, _ -> :ok
    end
  end
end
