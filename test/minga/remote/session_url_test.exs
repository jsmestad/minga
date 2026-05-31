defmodule Minga.Remote.SessionURLTest do
  use ExUnit.Case, async: true

  alias Minga.Remote.SessionURL

  test "parses ssh URL with user, host, port, and server-side path" do
    assert {:ok, url} = SessionURL.parse("ssh://dev@box.example:2222/work/app")

    assert url.user == "dev"
    assert url.host == "box.example"
    assert url.port == 2222
    assert url.path == "/work/app"
    assert SessionURL.ssh_target(url) == "dev@box.example"
    assert SessionURL.server_name(url) == "dev@box.example"
  end

  test "requires an ssh scheme and host" do
    assert {:error, :invalid_url} = SessionURL.parse("http://box/work")
    assert {:error, :invalid_url} = SessionURL.parse("ssh:///work")
  end

  test "requires a path for session URLs but not host URLs" do
    assert {:error, :missing_path} = SessionURL.parse("ssh://box")
    assert {:ok, %{path: nil}} = SessionURL.parse("ssh://box", require_path?: false)
  end

  test "rejects SSH option-like or whitespace-bearing targets" do
    assert {:error, :invalid_url} = SessionURL.parse("ssh://-oProxyCommand=calc/work")
    assert {:error, :invalid_url} = SessionURL.parse("ssh://-dev@box/work")
    assert {:error, :invalid_url} = SessionURL.parse("ssh://dev box/work")
  end
end
