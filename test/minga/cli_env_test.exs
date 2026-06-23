defmodule Minga.CLIEnvTest do
  use ExUnit.Case, async: true

  alias Minga.CLI

  test "distribution_cookie/1 returns an error when an explicit cookie file cannot be read" do
    missing_path =
      Path.join(System.tmp_dir!(), "missing-cookie-#{System.unique_integer([:positive])}")

    assert {:error, message} = CLI.distribution_cookie(%{cookie_file: missing_path})
    assert message =~ "Failed to read Erlang cookie file"
    assert message =~ ":enoent"
  end

  test "distribution_cookie/1 returns the cookie from flags when present" do
    cookie = "abcdefghijklmnopqrstuvwxyz123456"
    assert {:ok, ^cookie} = CLI.distribution_cookie(%{cookie: cookie})
  end

  test "gateway_port/1 returns an error for invalid gateway_port_env" do
    assert CLI.gateway_port(%{gateway_port: nil, gateway_port_env: "abc"}) ==
             {:error, "MINGA_GATEWAY_PORT must be a TCP port between 1 and 65535"}
  end

  test "gateway_port/1 uses valid gateway_port_env" do
    assert CLI.gateway_port(%{gateway_port: nil, gateway_port_env: "4901"}) == {:ok, 4901}
  end
end
