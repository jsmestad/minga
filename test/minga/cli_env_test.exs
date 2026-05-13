defmodule Minga.CLIEnvTest do
  # Mutates process-wide environment variables used by CLI startup helpers.
  use ExUnit.Case, async: false

  alias Minga.CLI

  setup do
    previous_cookie = System.get_env("MINGA_COOKIE")
    previous_port = System.get_env("MINGA_GATEWAY_PORT")

    on_exit(fn ->
      restore_env("MINGA_COOKIE", previous_cookie)
      restore_env("MINGA_GATEWAY_PORT", previous_port)
    end)

    :ok
  end

  test "distribution_cookie/1 returns an error when an explicit cookie file cannot be read" do
    System.put_env("MINGA_COOKIE", "abcdefghijklmnopqrstuvwxyz123456")

    missing_path =
      Path.join(System.tmp_dir!(), "missing-cookie-#{System.unique_integer([:positive])}")

    assert {:error, message} = CLI.distribution_cookie(%{cookie_file: missing_path})
    assert message =~ "Failed to read Erlang cookie file"
    assert message =~ ":enoent"
  end

  test "gateway_port/1 returns an error for invalid MINGA_GATEWAY_PORT" do
    System.put_env("MINGA_GATEWAY_PORT", "abc")

    assert CLI.gateway_port(%{gateway_port: nil}) ==
             {:error, "MINGA_GATEWAY_PORT must be a TCP port between 1 and 65535"}
  end

  test "gateway_port/1 uses valid MINGA_GATEWAY_PORT" do
    System.put_env("MINGA_GATEWAY_PORT", "4901")

    assert CLI.gateway_port(%{gateway_port: nil}) == {:ok, 4901}
  end

  @spec restore_env(String.t(), String.t() | nil) :: :ok
  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
