defmodule MingaAgent.MCP.StdioTransportTest do
  # Spawns a real /bin/sh child to verify process-boundary env isolation.
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
end
